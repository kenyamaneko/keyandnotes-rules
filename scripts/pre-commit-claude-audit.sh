#!/usr/bin/env bash
# staged diff を別プロセスの Claude に共通ルールと対象リポのルールで審査させ、違反があれば commit を止める。対象リポのルートを第 1 引数に取る。

set -uo pipefail

readonly AUDIT_LOG_DIR="${HOME}/.claude/audit-logs"
readonly AUDIT_LOG_FILE="${AUDIT_LOG_DIR}/pre-commit-claude-audit.log"
readonly CONFIG_RELATIVE_PATH=".claude/audit-config.json"
readonly DIFF_CONTEXT_LINES=10

# 頻繁に走るため、速度と推論のバランスで sonnet を使う。
readonly AUDITOR_MODEL="claude-sonnet-5"

# auditor の context に収めるため、headless claude の基盤プロンプト分を差し引いた値にする。
readonly MAX_PROMPT_BYTES=350000

# これを下回るとチャンク分割しても監査が成立しないため、監査不能にする。
readonly MIN_DIFF_BUDGET_BYTES=20000

SHARED_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly SHARED_REPO_DIR
readonly BASE_RULES="${SHARED_REPO_DIR}/rules"
readonly COMMON_LIB="${SHARED_REPO_DIR}/scripts/claude-audit-common.sh"

readonly AUDIT_SCHEMA='{
  "type": "object",
  "required": ["violations"],
  "additionalProperties": false,
  "properties": {
    "violations": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["file", "line", "rule", "evidence", "why", "clarity", "fix_safety"],
        "additionalProperties": false,
        "properties": {
          "file": {"type": "string"},
          "line": {"type": "integer"},
          "rule": {"type": "string"},
          "evidence": {"type": "string"},
          "why": {"type": "string"},
          "clarity": {"type": "string", "enum": ["obvious", "interpretive"]},
          "fix_safety": {"type": "string", "enum": ["safe", "harmful"]}
        }
      }
    }
  }
}'

# 確認ダイアログの理由は保存されないため、ログに追記する。
log_audit_reason() {
  local decision="$1" repo="$2" text="$3"
  mkdir -p "$AUDIT_LOG_DIR" || return 0
  {
    printf '\n=== %s | decision=%s | target=%s ===\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$decision" "$repo"
    printf '%s\n' "$text"
  } >> "$AUDIT_LOG_FILE" || true
}

fail_closed() {
  printf '⚠️  pre-commit-claude-audit: %s 監査不能のため fail-safe で commit ブロック。\n' "$1" >&2
  exit 2
}

reject_command() {
  printf '\n❌ pre-commit-claude-audit: %s\n' "$1" >&2
  exit 2
}

# 実行前の hook からは、同じコマンドで git add してから commit する場合のステージ内容が見えず、無審査で commit が通るため、ステージ操作と commit の同居を拒否する。
reject_staging_with_commit() {
  local exec_cmd="$1"
  if printf '%s' "$exec_cmd" | grep -qE '(^|[[:space:]&|;`(])git[[:space:]]+(add|rm|mv)([[:space:]]|$)'; then
    reject_command 'git add/rm/mv と git commit が同一 Bash 呼び出しに含まれています。別の Bash 呼び出しに分けてから commit してください。'
  fi
  if printf '%s' "$exec_cmd" | grep -qE 'git[[:space:]]+commit[[:space:]]+(-[a-zA-Z]*a[a-zA-Z]*|--all)([[:space:]]|=|$)'; then
    reject_command 'git commit -a/-am/--all は commit 自体がステージ操作を兼ねます。git add で明示的にステージしてから commit してください。'
  fi
}

# commit の書き方 (git -C / cd / 素の commit) によらず、commit 先のディレクトリを求める。
resolve_commit_dir() {
  local cmd="$1" input="$2" dir before_commit
  dir=$(printf '%s' "$cmd" | grep -oE 'git[[:space:]]+-C[[:space:]]+"?[^"&|;[:space:]]+' | head -1 | sed -E 's|^git[[:space:]]+-C[[:space:]]+"?||')
  if [ -z "$dir" ]; then
    before_commit=$(printf '%s' "$cmd" | sed -E 's/git[[:space:]]+commit.*//')
    dir=$(printf '%s' "$before_commit" | grep -oE '(^|[&|;[:space:]])cd[[:space:]]+"?[^"&|;[:space:]]+' | tail -1 | sed -E 's|.*cd[[:space:]]+"?||')
  fi
  [ -z "$dir" ] && dir=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
  [ -z "$dir" ] && dir=$(pwd)
  printf '%s' "$dir"
}

absolute_git_common_dir() {
  (cd "$1" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
}

# commit 先の registry 上のリポ名・言語・前提ドキュメントを JSON で返す。worktree はチェックアウト場所に規則性がないため、共通 .git の親も照合候補に加える。
resolve_fleet_repo() {
  local registry="$1" commit_dir="$2" main_worktree_root="$3"
  python3 - "$expected_repo_root" "$registry" "$commit_dir" "$main_worktree_root" <<'PY'
import sys, os, json, yaml
repo_root, registry, commit_dir, main_worktree_root = sys.argv[1:5]
with open(os.path.join(repo_root, registry)) as f:
    data = yaml.safe_load(f)
candidates = {os.path.realpath(commit_dir), os.path.realpath(main_worktree_root)}
for r in data.get("repos", []):
    if os.path.realpath(os.path.join(repo_root, r["path"])) in candidates:
        print(json.dumps({"name": r["name"], "lang": r.get("lang", "none"), "prereq_docs": r.get("prereq_docs", [])}))
        break
PY
}

# 注入するルールを 1 行 1 件で返す。列は、ルール名・overlay 名・全面置換か・注入対象か (staged のファイル名と言語が条件に合うか)。
plan_rules() {
  jq -r --argjson auto "$auto_refs_json" --argjson names "$staged_names_json" --arg lang "$fleet_lang" '
    .rules as $configured
    | (([{rule: "principles.md"}] + ($auto | map({rule: .}))) | map(select(.rule as $r | $configured | all(.rule != $r)))) + $configured
    | .[]
    | (.files // null) as $files
    | (.lang // null) as $entry_lang
    | [.rule, (.overlay // .rule), (.replace // false),
       ((($files == null) or ($names | any(test($files)))) and ($entry_lang == null or $entry_lang == $lang))]
    | @tsv' "$config_file"
}

# 同じ相対パスの base と overlay を必ず対で出し、overlay の注入漏れを防ぐ。
emit_rule() {
  local rel="$1" overlay_name="$2" replace="$3"
  local base="${BASE_RULES}/${rel}"
  local overlay="${OVERLAY_RULES}/${overlay_name}"
  if [ "$replace" = "true" ]; then
    printf '\n\n## [overlay/%s] rules/%s (共通 %s を全面置換。本ファイルを正とする)\n' "$repo_name" "$overlay_name" "$rel"
    cat "$overlay"
    return 0
  fi
  printf '\n\n## [base] rules/%s\n' "$rel"
  cat "$base"
  if [ -f "$overlay" ]; then
    printf '\n\n## [overlay/%s] rules/%s (base と衝突する場合はこちらを優先)\n' "$repo_name" "$overlay_name"
    cat "$overlay"
  fi
}

build_prompt() {
  local entry rel overlay_name replace doc
  cat <<HEADER
あなたは ${repo_name} リポの SOFT (意味解釈型) ルール auditor です。
別の Claude が書いた staged diff を、以下の共通ルール (base) と ${repo_name} 固有ルール (overlay) に照らしてレビューしてください。
overlay は対応する base のルールを上書きする階層です。base と overlay が衝突する場合は overlay を優先して判定してください。

レビュー方針:
- 明確なルール違反のみ列挙する。主観的な改善提案・スタイル好みは含めない
- 各違反は file / line / rule / evidence / why / clarity / fix_safety を埋める。line は違反箇所の行番号 (diff の追加行) を必ず入れる
- 違反 0 件なら "violations": [] を返す

各違反を 2 軸で分類してください (hook が「worker が自律修正してよいか」を判定するのに使う):
- clarity (明白度):
  - "obvious"      = ルール文面に照らして違反が明白で、解釈の余地がない
  - "interpretive" = ルールの解釈次第で違反とみなされ、判断が分かれうる
- fix_safety (是正の安全性):
  - "safe"    = 違反を修正しても設計上の実害がない (例: docstring 追加, What コメント削除)
  - "harmful" = 是正することで設計上の実害が生じうる (例: 公開 API のリネーム, 責務分割による境界変更)
- diff だけでは確信が持てないときは "interpretive" / "harmful" (= 安全側) に倒す。自律修正は明白かつ安全な違反に限定するため

# 適用ルール (target repo: ${repo_name})
HEADER

  for entry in ${active_rules[@]+"${active_rules[@]}"}; do
    IFS='|' read -r rel overlay_name replace <<< "$entry"
    emit_rule "$rel" "$overlay_name" "$replace"
  done
  for doc in ${fleet_docs[@]+"${fleet_docs[@]}"}; do
    printf '\n\n## %s\n' "$doc"
    cat "${expected_repo_root}/${doc}"
  done

  printf '\n\n# 対象 staged diff\n\n```diff\n%s\n```\n\n# 出力\n指定スキーマの JSON のみを返してください。\n' "$1"
}

# 1 グループ分の diff を auditor にかけ、違反を all_violations に集約する。
audit_diff() {
  local out exit_code err_msg violations_type
  out=$(build_prompt "$1" | claude -p \
    --model "$AUDITOR_MODEL" \
    --tools "" \
    --output-format json \
    --json-schema "$AUDIT_SCHEMA" \
    --no-session-persistence 2>"$err_file")
  exit_code=$?
  [ "$exit_code" -ne 0 ] && fail_closed "Claude auditor 起動に失敗 (exit ${exit_code})。$(head -20 "$err_file" 2>/dev/null)"

  if [ "$(printf '%s' "$out" | jq -r '.is_error // false')" = "true" ]; then
    err_msg=$(printf '%s' "$out" | jq -r '.result // ""')
    fail_closed "Claude auditor が API エラー。${err_msg}"
  fi

  # jq は null の添字参照を length 0 とみなすため、欠落・型不正は type で見分ける。
  violations_type=$(printf '%s' "$out" | jq -r '.structured_output.violations | type' 2>/dev/null)
  if [ "$violations_type" != "array" ]; then
    fail_closed "auditor 出力の structured_output.violations が配列でない (type=${violations_type})。$(printf '%s' "$out" | jq -r '.result // ""' | head -c 500)"
  fi

  all_violations=$(jq -cn --argjson a "$all_violations" --argjson b "$(printf '%s' "$out" | jq -c '.structured_output.violations')" '$a + $b')
}

# 現在のグループに溜めた staged ファイルの diff をまとめて監査し、グループをリセットする。
flush_group() {
  [ "${#group_files[@]}" -eq 0 ] && return 0
  audit_diff "$(git diff --cached -U"$DIFF_CONTEXT_LINES" --diff-filter=ACM -- "${group_files[@]}" 2>/dev/null)"
  group_files=()
  group_bytes=0
}

# auditor の context に収まるよう、ファイル単位で diff をグループに分けて監査する。
audit_staged_files() {
  local file file_bytes
  group_files=()
  group_bytes=0
  for file in "${staged_files[@]}"; do
    file_bytes=$(git diff --cached -U"$DIFF_CONTEXT_LINES" --diff-filter=ACM -- "$file" 2>/dev/null | wc -c | tr -d ' ')
    if [ "$file_bytes" -gt "$diff_budget" ]; then
      fail_closed "単一ファイルの diff が監査予算を超過 (${file}: ${file_bytes} bytes > ${diff_budget})。当該ファイルの変更を分けてコミットしてください。"
    fi
    if [ $(( group_bytes + file_bytes )) -gt "$diff_budget" ]; then
      flush_group
    fi
    group_files+=("$file")
    group_bytes=$(( group_bytes + file_bytes ))
  done
  flush_group
}

format_violations() {
  jq -r '.[] | "- \(.file):\(.line)  [明白度: \(if .clarity == "obvious" then "明白" else "解釈次第" end) / 是正の安全性: \(if .fix_safety == "safe" then "実害なし" else "実害ありうる" end)]\n    rule: \(.rule)\n    evidence: \(.evidence)\n    why: \(.why)"'
}

emit_decision() {
  local decision="$1" reason="$2"
  log_audit_reason "$decision" "$repo_name" "$reason"
  jq -nc --arg d "$decision" --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
  exit 0
}

# auditor の stderr を捕捉する一時ファイル (並行 commit のレース回避に mktemp を使う)。
err_file=$(mktemp)
trap 'rm -f "$err_file"' EXIT

expected_repo_root="${1:-}"
[ -z "$expected_repo_root" ] && fail_closed '対象リポのルートが第 1 引数に渡されていない。'
expected_repo_root=$(cd "$expected_repo_root" 2>/dev/null && pwd -P) || fail_closed "対象リポのルート (${1}) が開けない。"

input=$(cat)
[ -z "$input" ] && fail_closed '空入力で起動。'
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || fail_closed 'JSON parse 失敗。'

# 文字列リテラルや HEREDOC 内の偶発マッチを避けるため、実行される部分だけを取り出す。
exec_cmd=$(printf '%s' "$cmd" | sed -E '/<</q' | sed -E 's/"[^"]*"//g; s/'\''[^'\'']*'\''//g')
printf '%s' "$exec_cmd" | grep -qE '(^|[[:space:]&|;`(])git[[:space:]]+commit' || exit 0
printf '%s' "$exec_cmd" | grep -qE 'git[[:space:]]+commit[[:space:]]+(--help|-h)([[:space:]]|$)' && exit 0
reject_staging_with_commit "$exec_cmd"

commit_dir=$(resolve_commit_dir "$cmd" "$input")
cd "$commit_dir" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

config_file="${expected_repo_root}/${CONFIG_RELATIVE_PATH}"
is_fleet=false
if [ -f "$config_file" ] && [ "$(jq -r 'has("fleet")' "$config_file" 2>/dev/null)" = "true" ]; then
  is_fleet=true
fi

# 対象リポ (その worktree を含む) 以外の commit にこのリポのルールを当てないため、監査しない。fleet は commit 先を registry から求める。
if [ "$is_fleet" = false ] && [ "$(absolute_git_common_dir "$commit_dir")" != "$(absolute_git_common_dir "$expected_repo_root")" ]; then
  exit 0
fi

[ -f "$config_file" ] || fail_closed "設定 (${config_file}) が見つからない。"
config_valid=$(jq -r '
  (.name | type == "string" and length > 0)
  and (.rules | type == "array") and all(.rules[]; .rule | type == "string")
  and (.exempt_overlays | type == "array")
  and (.exclude_pathspecs | type == "array")
  and (if has("fleet") then (.fleet.registry | type == "string") and (.fleet.extra_docs | type == "array") else true end)
' "$config_file" 2>/dev/null)
[ "$config_valid" = "true" ] || fail_closed "設定 (${config_file}) の形式が不正。name / rules / exempt_overlays / exclude_pathspecs が必要。fleet を使うときは fleet.registry と fleet.extra_docs も必要。"

repo_name=$(jq -r '.name' "$config_file")
OVERLAY_RULES="${expected_repo_root}/rules"

exclude_pathspecs=()
while IFS= read -r pathspec; do
  [ -n "$pathspec" ] && exclude_pathspecs+=("$pathspec")
done < <(jq -r '.exclude_pathspecs[]' "$config_file")

# 空配列の展開は bash 3.2 の set -u でエラーになるため、要素があるときだけ展開する。
staged_diff=$(git diff --cached -U"$DIFF_CONTEXT_LINES" --diff-filter=ACM -- . ${exclude_pathspecs[@]+"${exclude_pathspecs[@]}"} 2>/dev/null)
[ -z "$staged_diff" ] && exit 0
staged_names=$(git diff --cached --name-only --diff-filter=ACM -- . ${exclude_pathspecs[@]+"${exclude_pathspecs[@]}"} 2>/dev/null)
staged_files=()
while IFS= read -r file; do
  [ -n "$file" ] && staged_files+=("$file")
done <<< "$staged_names"

fleet_lang=""
fleet_docs=()
if [ "$is_fleet" = true ]; then
  fleet_registry=$(jq -r '.fleet.registry' "$config_file")
  main_worktree_root="$(dirname "$(absolute_git_common_dir "$commit_dir")")"
  fleet_repo=$(resolve_fleet_repo "$fleet_registry" "$commit_dir" "$main_worktree_root")
  [ -n "$fleet_repo" ] || fail_closed "commit 対象リポ (${main_worktree_root}) が ${fleet_registry} に未登録のため解決不能。登録が必要な場合は ${fleet_registry} への追記を人間に提案してください (Claude は rules/ 配下を書き換えない)。"
  repo_name=$(printf '%s' "$fleet_repo" | jq -r '.name')
  fleet_lang=$(printf '%s' "$fleet_repo" | jq -r '.lang')
  while IFS= read -r doc; do
    [ -f "${expected_repo_root}/${doc}" ] && fleet_docs+=("$doc")
  done < <(jq -r --argjson repo "$fleet_repo" '.fleet.extra_docs[], $repo.prereq_docs[]' "$config_file")
fi

# principles.md の @import 一覧を手書きで複製すると更新に追従しないため、動的に導出する。
[ -f "$COMMON_LIB" ] || fail_closed "共有ロジック (${COMMON_LIB}) が見つからない。"
# shellcheck source=/dev/null
source "$COMMON_LIB"

configured_rule_names=()
while IFS= read -r rule_name; do
  configured_rule_names+=("$rule_name")
done < <(jq -r '.rules[].rule' "$config_file")
auto_refs=$(kn_auto_inject_refs "$BASE_RULES" "${BASE_RULES}/principles.md" ${configured_rule_names[@]+"${configured_rule_names[@]}"}) \
  || fail_closed 'principles.md が参照する base ルールの自動導出に失敗。'
auto_refs_json=$(printf '%s\n' "$auto_refs" | jq -R . | jq -sc 'map(select(length > 0))')
staged_names_json=$(printf '%s\n' "$staged_names" | jq -R . | jq -sc 'map(select(length > 0))')

rule_plan=$(plan_rules) || fail_closed "設定 (${config_file}) の rules の条件 (files) が不正。"

# build_prompt はパイプのサブシェルで走り exit が親に伝わらないため、ルールの存在検証はここで済ませる。
active_rules=()
covered_overlays=""
while IFS=$'\t' read -r rel overlay_name replace active; do
  [ -z "$rel" ] && continue
  covered_overlays="${covered_overlays}"$'\n'"${overlay_name}"
  if [ "$replace" = "true" ]; then
    [ -f "${OVERLAY_RULES}/${overlay_name}" ] || fail_closed "${repo_name} の overlay rules/${overlay_name} が見つからず、共通 ${rel} を置き換えられない。"
  else
    [ -f "${BASE_RULES}/${rel}" ] || fail_closed "共通ルール rules/${rel} が見つからず実効ルール集を構成できない。"
    if [ "$overlay_name" != "$rel" ] && [ ! -f "${OVERLAY_RULES}/${overlay_name}" ]; then
      fail_closed "${repo_name} の overlay rules/${overlay_name} が見つからず実効ルール集を構成できない。"
    fi
  fi
  [ "$active" = "true" ] && active_rules+=("${rel}|${overlay_name}|${replace}")
done <<< "$rule_plan"

# overlay を足しても設定に書き忘れると監査から静かに漏れるため、注入されない overlay を検知して止める。
while IFS= read -r overlay_file; do
  rel="${overlay_file#"${OVERLAY_RULES}/"}"
  jq -e --arg p "$rel" '.exempt_overlays | index($p) != null' "$config_file" >/dev/null && continue
  printf '%s\n' "$covered_overlays" | grep -qxF -- "$rel" \
    || fail_closed "overlay rules/${rel} が監査に注入されない。.claude/audit-config.json の rules に追加する (ルールでなければ exempt_overlays に追加する)。"
done < <(find "$OVERLAY_RULES" -type f -name '*.md' 2>/dev/null)

rules_bytes=$(build_prompt "" | wc -c | tr -d ' ')
diff_budget=$(( MAX_PROMPT_BYTES - rules_bytes ))
if [ "$diff_budget" -lt "$MIN_DIFF_BUDGET_BYTES" ]; then
  fail_closed "ルール群が大きく diff 予算を確保できない (rules=${rules_bytes} bytes, max=${MAX_PROMPT_BYTES})。"
fi

all_violations='[]'
audit_staged_files

violations_count=$(printf '%s' "$all_violations" | jq 'length')
[ "$violations_count" -eq 0 ] && exit 0

autofix=$(printf '%s' "$all_violations" | jq -c '[.[] | select(.clarity == "obvious" and .fix_safety == "safe")]')
escalate=$(printf '%s' "$all_violations" | jq -c '[.[] | select(.clarity != "obvious" or .fix_safety != "safe")]')
autofix_count=$(printf '%s' "$autofix" | jq 'length')
escalate_count=$(printf '%s' "$escalate" | jq 'length')

# auditor は 1 つの diff を一括で判定するため、明白な違反を先に deny で解消させ、残りは再 commit 時に ask で確認する。
if [ "$autofix_count" -gt 0 ]; then
  reason=$(
    printf '明白かつ修正に実害のないルール違反 %d 件を検出。principles「ルール違反への対応」に従い、自律修正してから再 commit してください:\n\n' "$autofix_count"
    printf '%s' "$autofix" | format_violations
    if [ "$escalate_count" -gt 0 ]; then
      printf '\n\n(解釈次第 / 是正に実害ありうる違反 %d 件は、上記修正後の再 commit で別途確認します。今は触れないでください。)' "$escalate_count"
    fi
    printf '\n\n検出が false positive だと判断する場合のみ、その理由を添えてユーザに確認してください。'
  )
  emit_decision "deny" "$reason"
fi

reason=$(
  printf 'Claude auditor が判断を要するルール違反 %d 件を検出。明白でない、または是正に設計上の実害がありうるため、修正可否を判断してください:\n\n' "$escalate_count"
  printf '%s' "$escalate" | format_violations
  printf '\n\n修正するなら拒否、意図的に commit するなら許可してください。'
)
emit_decision "ask" "$reason"
