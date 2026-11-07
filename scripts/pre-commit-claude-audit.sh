#!/usr/bin/env bash
# staged diff を別プロセスの Claude に共通ルールと commit 先リポのルールで審査させ、違反があれば commit を止める。全リポの設定を audit-repos.yaml に集約し、commit 先のリポは commit するディレクトリから求める。

set -uo pipefail

readonly AUDIT_LOG_DIR="${HOME}/.claude/audit-logs"
readonly AUDIT_LOG_FILE="${AUDIT_LOG_DIR}/pre-commit-claude-audit.log"
readonly DIFF_CONTEXT_LINES=10
readonly DEFAULT_OVERLAY_DIR="rules"

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
readonly REPOS_CONFIG_FILE="${SHARED_REPO_DIR}/scripts/audit-repos.yaml"

# shellcheck source=/dev/null
source "$COMMON_LIB" || { printf '⚠️  pre-commit-claude-audit: 共有ロジック (%s) を読み込めない。監査不能のため fail-safe で commit ブロック。\n' "$COMMON_LIB" >&2; exit 2; }

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

# 注入するルールを 1 行 1 件で返す。列は、ルール名・overlay 名・全面置換か・注入対象か (staged のファイル名が条件に合うか)。
plan_rules() {
  jq -r --argjson auto "$auto_refs_json" --argjson names "$staged_names_json" '
    .rules as $configured
    | (([{rule: "principles.md"}] + ($auto | map({rule: .}))) | map(select(.rule as $r | $configured | all(.rule != $r)))) + $configured
    | .[]
    | (.files // null) as $files
    | [.rule, (.overlay // .rule), (.replace // false),
       (($files == null) or ($names | any(test($files))))]
    | @tsv' "$config_file"
}

# overlay_dir が null のリポ (共通ルールそのものを置くリポ) には overlay が無い。
overlay_exists() {
  [ -n "$OVERLAY_RULES" ] && [ -f "${OVERLAY_RULES}/$1" ]
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
  if overlay_exists "$overlay_name"; then
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
  for doc in ${extra_docs[@]+"${extra_docs[@]}"}; do
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

input=$(cat)
[ -z "$input" ] && fail_closed '空入力で起動。'
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || fail_closed 'JSON parse 失敗。'

exec_cmd=$(kn_extract_exec_cmd "$cmd")
kn_is_commit_command "$exec_cmd" || exit 0
# 実行前の hook からは、同じコマンドでステージしてから commit する場合のステージ内容が見えず、無審査で commit が通るため、ステージ操作と commit の同居を拒否する。
staging_message=$(kn_find_staging_with_commit "$exec_cmd") && reject_command "$staging_message"

commit_dir=$(kn_resolve_commit_dir "$cmd" "$input")
cd "$commit_dir" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

repo_name=$(kn_repo_name "$commit_dir")
# 子リポは本体のチェックアウトの隣にある別リポの overlay と前提ドキュメントを参照するため、worktree でなく本体のチェックアウトを基準にする。
expected_repo_root=$(kn_main_checkout_root "$commit_dir") || fail_closed "commit 先 (${commit_dir}) の本体のチェックアウトを求められない。"

[ -f "$REPOS_CONFIG_FILE" ] || fail_closed "全リポの設定 (${REPOS_CONFIG_FILE}) が見つからない。"
repos_config=$(kn_load_repos_config "$REPOS_CONFIG_FILE") || fail_closed "$repos_config"
kn_is_excluded_repo "$repos_config" "$repo_name" && exit 0
repo_entry=$(printf '%s' "$repos_config" | jq -c --arg name "$repo_name" '.repos[$name] // empty')
[ -n "$repo_entry" ] || fail_closed "リポ ${repo_name} の設定が ${REPOS_CONFIG_FILE} に無い。監査する場合は rules を、監査しない場合は excluded: true を書いて追加してください。"

# 検証と各所の jq が同じ入力を読めるよう、リポの設定を一時ファイルに書き出す。
config_file=$(mktemp)
trap 'rm -f "$err_file" "$config_file"' EXIT
printf '%s' "$repo_entry" > "$config_file"

config_valid=$(jq -r '
  (.rules | type == "array") and all(.rules[]; .rule | type == "string")
  and (.exempt_overlays | type == "array")
  and (.exclude_pathspecs | type == "array")
  and (.extra_docs | type == "array")
  and (.overlay_dir | type == "string" or . == null)
' "$config_file" 2>/dev/null)
[ "$config_valid" = "true" ] || fail_closed "リポ ${repo_name} の設定 (${REPOS_CONFIG_FILE}) の形式が不正。rules / exempt_overlays / exclude_pathspecs / extra_docs / overlay_dir が必要。"

overlay_dir=$(jq -r '.overlay_dir // ""' "$config_file")
OVERLAY_RULES=""
[ -n "$overlay_dir" ] && OVERLAY_RULES="${expected_repo_root}/${overlay_dir}"

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

extra_docs=()
while IFS= read -r doc; do
  [ -z "$doc" ] && continue
  [ -f "${expected_repo_root}/${doc}" ] || fail_closed "リポ ${repo_name} の前提ドキュメント ${doc} が見つからない。"
  extra_docs+=("$doc")
done < <(jq -r '.extra_docs[]' "$config_file")

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
    overlay_exists "$overlay_name" || fail_closed "${repo_name} の overlay rules/${overlay_name} が見つからず、共通 ${rel} を置き換えられない。"
  else
    [ -f "${BASE_RULES}/${rel}" ] || fail_closed "共通ルール rules/${rel} が見つからず実効ルール集を構成できない。"
    if [ "$overlay_name" != "$rel" ] && ! overlay_exists "$overlay_name"; then
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
    || fail_closed "overlay rules/${rel} が監査に注入されない。全リポの設定 (audit-repos.yaml) の rules に追加する (ルールでなければ exempt_overlays に追加する)。"
done < <([ -n "$OVERLAY_RULES" ] && find "$OVERLAY_RULES" -type f -name '*.md' 2>/dev/null)

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
