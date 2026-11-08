#!/usr/bin/env bash
# staged diff を別プロセスの Claude に共通ルールと commit 先リポのルールで審査させ、違反があれば commit を止める。全リポの設定を audit-repos.yaml に集約し、commit 先のリポは commit するディレクトリから求める。

set -uo pipefail

readonly AUDIT_LOG_DIR="${HOME}/.claude/audit-logs"
readonly AUDIT_LOG_FILE="${AUDIT_LOG_DIR}/pre-commit-claude-audit.log"
readonly DIFF_CONTEXT_LINES=10
readonly DEFAULT_OVERLAY_DIR="rules"

# package-lock.json は生成されるファイルで、ルール違反の対象にならないため、リポによらず監査する差分から外す。
readonly EXCLUDED_PATHSPECS=(':(exclude,glob)**/package-lock.json')

readonly LANG_RULES_JSON='[
  {"rule": "lang/iac.md", "files": "\\.tf$"},
  {"rule": "lang/python.md", "files": "\\.py$"},
  {"rule": "lang/go.md", "files": "\\.go$"},
  {"rule": "lang/typescript.md", "files": "\\.(ts|tsx)$"},
  {"rule": "lang/csharp.md", "files": "\\.(cs|asmdef)$"},
  {"rule": "lang/dart.md", "files": "\\.dart$"},
  {"rule": "lang/kotlin.md", "files": "\\.kts?$"}
]'

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

# 注入するルールを 1 行 1 件で返す。列は、ルール名・注入対象か (言語のルールは、staged のファイル名が条件に合うか)。
plan_rules() {
  jq -nr --argjson auto "$auto_refs_json" --argjson names "$staged_names_json" --argjson lang "$LANG_RULES_JSON" '
    ([{rule: "principles.md"}] + ($auto | map({rule: .})) + $lang)
    | .[]
    | (.files // null) as $files
    | [.rule, (($files == null) or ($names | any(test($files))))]
    | @tsv'
}

# overlay_dir が共通ルールの置き場と同じリポ (共通ルールそのものを置くリポ) には overlay が無い。
overlay_exists() {
  [ -n "$OVERLAY_RULES" ] && [ -f "${OVERLAY_RULES}/$1" ]
}

# 同じ相対パスの base と overlay を必ず対で出し、overlay の注入漏れを防ぐ。
emit_rule() {
  local rel="$1"
  printf '\n\n## [base] rules/%s\n' "$rel"
  cat "${BASE_RULES}/${rel}"
  if overlay_exists "$rel"; then
    printf '\n\n## [overlay/%s] rules/%s (base と衝突する場合はこちらを優先)\n' "$repo_name" "$rel"
    cat "${OVERLAY_RULES}/${rel}"
  fi
}

# 共通ルールに対応するファイルが無い overlay は、リポ固有のルールとして単独で出す。
emit_standalone_overlay() {
  printf '\n\n## [overlay/%s] rules/%s (リポ固有のルール。base と衝突する場合はこちらを優先)\n' "$repo_name" "$1"
  cat "${OVERLAY_RULES}/$1"
}

build_prompt() {
  local rel doc
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

  for rel in ${active_rules[@]+"${active_rules[@]}"}; do
    emit_rule "$rel"
  done
  for rel in ${standalone_overlays[@]+"${standalone_overlays[@]}"}; do
    emit_standalone_overlay "$rel"
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

# 確認ダイアログは長い理由の後半を省略するため、指摘ごとの 1 行の一覧を詳細より前に出す。
format_violation_summary() {
  jq -r '.[] | "- \(.file):\(.line)  \(.rule)"'
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
kn_is_audit_target "$repos_config" "$repo_name" || exit 0

# 検証と各所の jq が同じ入力を読めるよう、リポの設定を一時ファイルに書き出す。
config_file=$(mktemp)
trap 'rm -f "$err_file" "$config_file"' EXIT
printf '%s' "$repos_config" | jq -c --arg name "$repo_name" '.repos[$name] // {}' > "$config_file"

config_valid=$(jq -r '
  type == "object"
  and ((keys - ["overlay_dir", "extra_docs"]) | length == 0)
  and (if has("overlay_dir") then (.overlay_dir | type == "string" and length > 0) else true end)
  and ((.extra_docs // []) | type == "array" and all(.[]; type == "string"))
' "$config_file" 2>/dev/null)
[ "$config_valid" = "true" ] || fail_closed "リポ ${repo_name} の設定 (${REPOS_CONFIG_FILE}) の形式が不正。書けるのは overlay_dir (空でない文字列) と extra_docs (文字列の配列) だけ。"

overlay_dir=$(jq -r --arg default "$DEFAULT_OVERLAY_DIR" '.overlay_dir // $default' "$config_file")
overlay_path=$(cd "${expected_repo_root}/${overlay_dir}" 2>/dev/null && pwd -P)
if [ -z "$overlay_path" ] && jq -e 'has("overlay_dir")' "$config_file" >/dev/null; then
  fail_closed "リポ ${repo_name} の設定 (${REPOS_CONFIG_FILE}) の overlay_dir ${overlay_dir} が見つからない。リポのルートからの正しいパスに直すか、overlay_dir の行を消して。"
fi
OVERLAY_RULES=""
[ -n "$overlay_path" ] && [ "$overlay_path" != "$BASE_RULES" ] && OVERLAY_RULES="$overlay_path"

staged_diff=$(git diff --cached -U"$DIFF_CONTEXT_LINES" --diff-filter=ACM -- . "${EXCLUDED_PATHSPECS[@]}" 2>/dev/null)
[ -z "$staged_diff" ] && exit 0
staged_names=$(git diff --cached --name-only --diff-filter=ACM -- . "${EXCLUDED_PATHSPECS[@]}" 2>/dev/null)
staged_files=()
while IFS= read -r file; do
  [ -n "$file" ] && staged_files+=("$file")
done <<< "$staged_names"

extra_docs=()
while IFS= read -r doc; do
  [ -z "$doc" ] && continue
  [ -f "${expected_repo_root}/${doc}" ] || fail_closed "リポ ${repo_name} の前提ドキュメント ${doc} が見つからない。"
  extra_docs+=("$doc")
done < <(jq -r '(.extra_docs // [])[]' "$config_file")

auto_refs=$(kn_auto_inject_refs "$BASE_RULES" "${BASE_RULES}/principles.md") \
  || fail_closed 'principles.md が参照する base ルールの自動導出に失敗。'
auto_refs_json=$(printf '%s\n' "$auto_refs" | jq -R . | jq -sc 'map(select(length > 0))')
staged_names_json=$(printf '%s\n' "$staged_names" | jq -R . | jq -sc 'map(select(length > 0))')

rule_plan=$(plan_rules) || fail_closed "言語のルールの条件 (files) が不正。"

# build_prompt はパイプのサブシェルで走り exit が親に伝わらないため、ルールの存在検証はここで済ませる。
active_rules=()
while IFS=$'\t' read -r rel active; do
  [ -z "$rel" ] && continue
  [ -f "${BASE_RULES}/${rel}" ] || fail_closed "共通ルール rules/${rel} が見つからず実効ルール集を構成できない。"
  [ "$active" = "true" ] && active_rules+=("$rel")
done <<< "$rule_plan"

standalone_overlays=()
if [ -n "$OVERLAY_RULES" ]; then
  while IFS= read -r overlay_file; do
    rel="${overlay_file#"${OVERLAY_RULES}/"}"
    [ -f "${BASE_RULES}/${rel}" ] || standalone_overlays+=("$rel")
  done < <(find "$OVERLAY_RULES" -type f -name '*.md' | sort)
fi

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
    printf '明白かつ修正に実害のないルール違反 %d 件を検出。principles「ルール違反への対応」に従い、自律修正してから再 commit してください (全文: %s):\n\n' "$autofix_count" "$AUDIT_LOG_FILE"
    printf '%s' "$autofix" | format_violation_summary
    printf '\n'
    printf '%s' "$autofix" | format_violations
    if [ "$escalate_count" -gt 0 ]; then
      printf '\n\n(解釈次第 / 是正に実害ありうる違反 %d 件は、上記修正後の再 commit で別途確認します。今は触れないでください。)' "$escalate_count"
    fi
    printf '\n\n検出が false positive だと判断する場合のみ、その理由を添えてユーザに確認してください。'
  )
  emit_decision "deny" "$reason"
fi

reason=$(
  printf 'Claude auditor が判断を要するルール違反 %d 件を検出。明白でない、または是正に設計上の実害がありうるため、修正可否を判断してください (全文: %s):\n\n' "$escalate_count" "$AUDIT_LOG_FILE"
  printf '%s' "$escalate" | format_violation_summary
  printf '\n'
  printf '%s' "$escalate" | format_violations
  printf '\n\n修正するなら拒否、意図的に commit するなら許可してください。'
)
emit_decision "ask" "$reason"
