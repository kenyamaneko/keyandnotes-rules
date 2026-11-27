#!/usr/bin/env bash
# ステージした差分を別プロセスの Claude に共通ルールとコミット先リポジトリのルールで審査させ、違反があればコミットを止める。全リポジトリの設定を audit-repos.yaml に集約し、コミット先のリポジトリはコミットするディレクトリから求める。コミットが作られるまでの再審査は、前に審査した Claude の会話を続け、前回からの変更を審査させる。

set -uo pipefail

readonly AUDIT_LOG_DIR="${HOME}/.claude/audit-logs"
AUDIT_LOG_FILE="${AUDIT_LOG_DIR}/pre-commit-claude-audit-$(date '+%Y-%m-%d').log"
readonly AUDIT_LOG_FILE
readonly DIFF_CONTEXT_LINES=10
readonly DEFAULT_OVERLAY_DIR="rules"

# package-lock.json は生成されるファイルで、ルール違反の対象にならないため、リポジトリによらず監査する差分から外す。
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

# 残る監査の Claude の会話がコミット先のリポジトリの会話の一覧に混ざらないようにするため、監査の Claude は専用の作業ディレクトリで動かす。
readonly AUDITOR_WORK_DIR="${HOME}/.claude/kn-commit-audit-sessions"
readonly AUDITOR_STATE_FILE_NAME="kn-commit-auditors.json"

readonly ERROR_OUTPUT_MAX_LINES=20
readonly AUDITOR_RESULT_MAX_BYTES=500

SHARED_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly SHARED_REPO_DIR
readonly BASE_RULES="${SHARED_REPO_DIR}/rules"
readonly COMMON_LIB="${SHARED_REPO_DIR}/scripts/commit-audit/claude-audit-common.sh"

# shellcheck source=/dev/null
source "$COMMON_LIB" || { printf '⚠️  pre-commit-claude-audit: 共有ロジック (%s) を読み込めない。監査不能のため fail-safe で commit ブロック。\n' "$COMMON_LIB" >&2; exit 2; }

readonly AUDIT_LOG_BAR_WIDTH=80
readonly AUDIT_LOG_DETAIL_INDENT_WIDTH=16

repeat_char() {
  printf '%*s' "$2" '' | tr ' ' "$1"
}

AUDIT_LOG_ENTRY_TOP_BAR="$(repeat_char '#' "$AUDIT_LOG_BAR_WIDTH")"
AUDIT_LOG_ENTRY_BOTTOM_BAR="$(repeat_char '=' "$AUDIT_LOG_BAR_WIDTH")"
AUDIT_LOG_DETAIL_INDENT="$(repeat_char ' ' "$AUDIT_LOG_DETAIL_INDENT_WIDTH")"
readonly AUDIT_LOG_ENTRY_TOP_BAR AUDIT_LOG_ENTRY_BOTTOM_BAR AUDIT_LOG_DETAIL_INDENT
readonly VIOLATION_JQ_DEFINITIONS='def is_autofix: .clarity == "obvious" and .fix_safety == "safe";
def clarity_label: if .clarity == "obvious" then "🟢明白" else "🟡解釈次第" end;
def safety_label: if .fix_safety == "safe" then "🟢実害なし" else "🔴実害ありうる" end;
def kind_label: if is_autofix then "自律修正" else "要確認" end;'
readonly AUDIT_LOG_ENTRY_FORMAT="${VIOLATION_JQ_DEFINITIONS}"'
{allow: "違反なし (allow)", allow_no_diff: "監査する差分なし (allow)", deny: "自律修正してから再 commit (deny)", ask: "確認が必要 (ask)"} as $decision_labels
| sort_by(if is_autofix then 0 else 1 end) as $items
| ($items | length) as $total
| ($items | map(select(is_autofix)) | length) as $autofix_count
| [
    $top_bar,
    "# 監査 \($time)",
    "# 対象リポジトリ: \($repo)",
    "# 判定: \($decision_labels[$decision])",
    "# 指摘: \($total) 件 (自律修正 \($autofix_count) 件 / 要確認 \($total - $autofix_count) 件)",
    $top_bar,
    ""
  ] + [
    $items | to_entries[] | .key as $index | .value
    | "[指摘 \($index + 1)/\($total)] \(kind_label)\n"
      + "  ファイル:     \(.file) の \(.line) 行目\n"
      + "  違反したルール: \(.rule)\n"
      + "  明白度:       \(clarity_label)\n"
      + "  是正の安全性:  \(safety_label)\n"
      + "  該当箇所:     \(.evidence | gsub("\n"; "\n" + $detail_indent))\n"
      + "  理由:         \(.why)\n"
  ] + [$bottom_bar]
| join("\n")'

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

# deny の確認ダイアログには要確認の指摘が出ないため、全指摘をログに追記する。
log_audit_entry() {
  local decision="$1" repo="$2" violations="$3"
  mkdir -p "$AUDIT_LOG_DIR" || return 1
  {
    printf '\n\n'
    printf '%s' "$violations" | jq -r \
      --arg decision "$decision" \
      --arg repo "$repo" \
      --arg time "$(date '+%Y-%m-%d %H:%M:%S %z')" \
      --arg top_bar "$AUDIT_LOG_ENTRY_TOP_BAR" \
      --arg bottom_bar "$AUDIT_LOG_ENTRY_BOTTOM_BAR" \
      --arg detail_indent "$AUDIT_LOG_DETAIL_INDENT" \
      "$AUDIT_LOG_ENTRY_FORMAT"
  } >> "$AUDIT_LOG_FILE"
}

fail_closed() {
  printf '⚠️  pre-commit-claude-audit: %s 監査不能のため fail-safe で commit ブロック。表示した原因を解消してから、もう一度コミットしてください。\n' "$1" >&2
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

# overlay_dir が共通ルールの置き場と同じリポジトリ (共通ルールそのものを置くリポジトリ) には overlay が無い。
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

# 共通ルールに対応するファイルが無い overlay は、リポジトリ固有のルールとして単独で出す。
emit_standalone_overlay() {
  printf '\n\n## [overlay/%s] rules/%s (リポジトリ固有のルール。base と衝突する場合はこちらを優先)\n' "$repo_name" "$1"
  cat "${OVERLAY_RULES}/$1"
}

build_prompt() {
  local rel doc
  cat <<HEADER
あなたは ${repo_name} リポジトリの SOFT (意味解釈型) ルール auditor です。
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
- 文言の違反 (documentation.md の「整形」「語の選び方」「コード上の名前の書き方」「冗長の排除」「見出しの付け方」。テスト名を除く) は、表現を直すだけで設計に影響しないため、fix_safety は常に "safe"、clarity は規約の文面に当たるなら "obvious" にする。diff だけで確信が持てなくても "interpretive" に倒さない
- 文言の違反以外で、diff だけでは確信が持てないときは "interpretive" / "harmful" (= 安全側) に倒す。自律修正は明白かつ安全な違反に限定するため

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

build_re_audit_prompt() {
  local delta="$1" assigned_files="$2"
  printf '前回の審査のあとに、staged の内容が変わりました。同じルールとレビュー方針で、あなたの担当ファイルについて、次の違反を violations に返してください。line には今の内容の行番号を入れてください。\n- 前回までに指摘した違反のうち、今の内容に残っているもの\n- 下の diff で新しく生じた違反\n'
  printf '\n# 担当ファイル\n%s\n' "$assigned_files"
  printf '\n# 前回審査した内容から今の内容への変更\n\n```diff\n%s\n```\n\n# 出力\n指定スキーマの JSON のみを返してください。\n' "$delta"
}

# プロンプトを監査の Claude に渡し、会話の ID と違反を受け取る。会話の ID を渡すと、その会話を続ける。
run_auditor() {
  local prompt="$1" resume_id="$2" out exit_code err_msg violations_type restart_hint=""
  local resume_args=()
  if [ -n "$resume_id" ]; then
    resume_args=(--resume "$resume_id")
    restart_hint=" 最初から審査し直すときは、${state_file} を削除してください。"
  fi
  # 親のフックが監査の出力を報告の雛形でないとして差し戻すのを防ぐため、フックを切る。
  out=$(printf '%s' "$prompt" | (cd "$AUDITOR_WORK_DIR" && claude -p \
    --model "$AUDITOR_MODEL" \
    --settings '{"disableAllHooks": true}' \
    --tools "" \
    --output-format json \
    --json-schema "$AUDIT_SCHEMA" \
    ${resume_args[@]+"${resume_args[@]}"}) 2>"$err_file")
  exit_code=$?
  [ "$exit_code" -ne 0 ] && fail_closed "Claude auditor 起動に失敗 (exit ${exit_code})。$(head -n "$ERROR_OUTPUT_MAX_LINES" "$err_file" 2>/dev/null)${restart_hint}"

  if [ "$(printf '%s' "$out" | jq -r '.is_error // false')" = "true" ]; then
    err_msg=$(printf '%s' "$out" | jq -r '.result // ""')
    fail_closed "Claude auditor が API エラー。${err_msg}${restart_hint}"
  fi

  # jq は null の添字参照を length 0 とみなすため、欠落・型不正は type で見分ける。
  violations_type=$(printf '%s' "$out" | jq -r '.structured_output.violations | type' 2>/dev/null)
  if [ "$violations_type" != "array" ]; then
    fail_closed "auditor 出力の structured_output.violations が配列でない (type=${violations_type})。$(printf '%s' "$out" | jq -r '.result // ""' | head -c "$AUDITOR_RESULT_MAX_BYTES")${restart_hint}"
  fi

  auditor_result=$(printf '%s' "$out" | jq -ce 'select(.session_id | type == "string") | {session_id, violations: .structured_output.violations}') \
    || fail_closed "auditor 出力に会話の ID (session_id) が無い。${restart_hint}"
}

# 現在のグループのファイルを、新しい監査の Claude に監査させる。
flush_group() {
  [ "${#group_files[@]}" -eq 0 ] && return 0
  local group_files_json
  run_auditor "$(build_prompt "$(kn_diff_staged_files "$DIFF_CONTEXT_LINES" "${group_files[@]}" 2>/dev/null)")" ""
  group_files_json=$(printf '%s\n' "${group_files[@]}" | jq -R . | jq -sc .)
  auditors=$(printf '%s' "$auditors" | jq -c --argjson result "$auditor_result" --argjson files "$group_files_json" --argjson diff_bytes "$group_bytes" \
    '. + [$result + {files: $files, diff_bytes: $diff_bytes}]')
  group_files=()
  group_bytes=0
}

# まだ担当がいないファイルを、新しい監査の Claude に監査させる。
audit_unassigned_files() {
  local file file_bytes unassigned_names
  unassigned_names=$(printf '%s' "$auditors" | jq -r --argjson staged "$staged_names_json" '$staged - [.[].files[]] | .[]') \
    || fail_closed "担当の auditor がいないファイルを求められない。最初から審査し直すときは、${state_file} を削除してください。"
  group_files=()
  group_bytes=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    file_bytes=$(kn_diff_staged_files "$DIFF_CONTEXT_LINES" "$file" 2>/dev/null | wc -c | tr -d ' ')
    if [ "$file_bytes" -gt "$diff_budget" ]; then
      fail_closed "単一ファイルの diff が監査予算を超過 (${file}: ${file_bytes} bytes > ${diff_budget})。当該ファイルの変更を分けてコミットしてください。"
    fi
    if [ $(( group_bytes + file_bytes )) -gt "$diff_budget" ]; then
      flush_group
    fi
    group_files+=("$file")
    group_bytes=$(( group_bytes + file_bytes ))
  done <<< "$unassigned_names"
  flush_group
}

# 前回の審査のあとの変更を、前に審査した監査の Claude に審査させる。
re_audit_changes() {
  local previous_tree="$1" changed_names changed_names_json delta delta_bytes indexes index auditor total_bytes
  local restart_hint="最初から審査し直すときは、${state_file} を削除してください。"
  # 名前を変える前のファイルを担当する監査の Claude も選ぶため、名前の変更を削除と追加に分けて一覧にする。
  changed_names=$(git diff --name-only -z --no-renames "$previous_tree" "$staged_tree" -- . "${EXCLUDED_PATHSPECS[@]}" 2>"$err_file" | tr '\0' '\n') \
    || fail_closed "前回審査した内容との違いを取れない。$(head -n "$ERROR_OUTPUT_MAX_LINES" "$err_file" 2>/dev/null) ${restart_hint}"
  [ -z "$changed_names" ] && return 0
  delta=$(git diff -U"$DIFF_CONTEXT_LINES" -M "$previous_tree" "$staged_tree" -- . "${EXCLUDED_PATHSPECS[@]}" 2>"$err_file") \
    || fail_closed "前回審査した内容からの変更を取れない。$(head -n "$ERROR_OUTPUT_MAX_LINES" "$err_file" 2>/dev/null) ${restart_hint}"
  delta_bytes=$(printf '%s' "$delta" | wc -c | tr -d ' ')

  changed_names_json=$(printf '%s\n' "$changed_names" | jq -R . | jq -sc .)
  # 同じコミットに向けた審査を同じ会話で続けるため、再試行で加えたファイルは、変更が監査予算に収まる前の監査の Claude の担当に加える。
  auditors=$(printf '%s' "$auditors" | jq -c --argjson staged "$staged_names_json" --argjson changed "$changed_names_json" \
    --argjson delta_bytes "$delta_bytes" --argjson budget "$diff_budget" '
    ($staged - [.[].files[]] | map(select(IN($changed[])))) as $added
    | ([to_entries[] | select(.value.diff_bytes + $delta_bytes <= $budget)] | min_by(.value.diff_bytes) | .key) as $index
    | if $index == null then . else .[$index].files += $added end') \
    || fail_closed "再試行で加えたファイルを auditor の担当に加えられない。${restart_hint}"
  indexes=$(printf '%s' "$auditors" | jq -r --argjson changed "$changed_names_json" \
    'to_entries[] | select((.value.violations | length > 0) or any(.value.files[]; IN($changed[]))) | .key') \
    || fail_closed "前回の審査の記録から、続きを審査させる auditor を選べない。${restart_hint}"
  for index in $indexes; do
    auditor=$(printf '%s' "$auditors" | jq -c --argjson index "$index" '.[$index]')
    # 続ける会話には前回までに渡した差分が残るため、合計が監査予算に収まるかを確かめる。
    total_bytes=$(( $(printf '%s' "$auditor" | jq -r '.diff_bytes') + delta_bytes ))
    [ "$total_bytes" -gt "$diff_budget" ] && fail_closed "auditor の会話に渡す diff の合計が監査予算を超過 (${total_bytes} bytes > ${diff_budget})。${restart_hint}"
    run_auditor "$(build_re_audit_prompt "$delta" "$(printf '%s' "$auditor" | jq -r '.files[]')")" "$(printf '%s' "$auditor" | jq -r '.session_id')"
    auditors=$(printf '%s' "$auditors" | jq -c --argjson index "$index" --argjson result "$auditor_result" --argjson total_bytes "$total_bytes" \
      '.[$index] += $result + {diff_bytes: $total_bytes}')
  done
}

save_auditor_state() {
  jq -n --arg head "$head_commit" --arg tree "$staged_tree" --argjson auditors "$auditors" \
    '{head: $head, tree: $tree, auditors: $auditors}' > "$state_file" \
    || fail_closed "審査の記録 (${state_file}) を書けない。"
}

format_violations() {
  jq -r "${VIOLATION_JQ_DEFINITIONS}"' .[] | "- \(.file):\(.line)  [明白度: \(clarity_label) / 是正の安全性: \(safety_label)]\n    rule: \(.rule)\n    evidence: \(.evidence)\n    why: \(.why)"'
}

# 確認ダイアログは長い理由の後半を省略するため、指摘ごとの 1 行の一覧を詳細より前に出す。
format_violation_summary() {
  jq -r '.[] | "- \(.file):\(.line)  \(.rule)"'
}

# git の pre-commit フックがコミットを通す判定を確かめるため、ステージ内容を監査の記録に残す。
record_pass() {
  kn_record_audit_pass claude || fail_closed '監査の記録を書けない。'
}

emit_decision() {
  local decision="$1" reason="$2"
  log_audit_entry "$decision" "$repo_name" "$all_violations" || fail_closed "監査ログ (${AUDIT_LOG_FILE}) を書けない。"
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
# 子リポジトリは本体のチェックアウトの隣にある別リポジトリの overlay と前提ドキュメントを参照するため、worktree でなく本体のチェックアウトを基準にする。
expected_repo_root=$(kn_main_checkout_root "$commit_dir") || fail_closed "commit 先 (${commit_dir}) の本体のチェックアウトを求められない。"

[ -f "$REPOS_CONFIG_FILE" ] || fail_closed "全リポジトリの設定 (${REPOS_CONFIG_FILE}) が見つからない。"
repos_config=$(kn_load_repos_config "$REPOS_CONFIG_FILE") || fail_closed "$repos_config"
kn_is_audit_target "$repos_config" "$repo_name" || exit 0

# 検証と各所の jq が同じ入力を読めるよう、リポジトリの設定を一時ファイルに書き出す。
config_file=$(mktemp)
trap 'rm -f "$err_file" "$config_file"' EXIT
printf '%s' "$repos_config" | jq -c --arg name "$repo_name" '.repos[$name] // {}' > "$config_file"

config_valid=$(jq -r '
  type == "object"
  and ((keys - ["overlay_dir", "extra_docs"]) | length == 0)
  and (if has("overlay_dir") then (.overlay_dir | type == "string" and length > 0) else true end)
  and ((.extra_docs // []) | type == "array" and all(.[]; type == "string"))
' "$config_file" 2>/dev/null)
[ "$config_valid" = "true" ] || fail_closed "リポジトリ ${repo_name} の設定 (${REPOS_CONFIG_FILE}) の形式が不正。書けるのは overlay_dir (空でない文字列) と extra_docs (文字列の配列) だけ。"

overlay_dir=$(jq -r --arg default "$DEFAULT_OVERLAY_DIR" '.overlay_dir // $default' "$config_file")
overlay_path=$(cd "${expected_repo_root}/${overlay_dir}" 2>/dev/null && pwd -P)
if [ -z "$overlay_path" ] && jq -e 'has("overlay_dir")' "$config_file" >/dev/null; then
  fail_closed "リポジトリ ${repo_name} の設定 (${REPOS_CONFIG_FILE}) の overlay_dir ${overlay_dir} が見つからない。リポジトリのルートからの正しいパスに直すか、overlay_dir の行を消して。"
fi
OVERLAY_RULES=""
[ -n "$overlay_path" ] && [ "$overlay_path" != "$BASE_RULES" ] && OVERLAY_RULES="$overlay_path"

staged_diff=$(git diff --cached -M -U"$DIFF_CONTEXT_LINES" --diff-filter="$KN_AUDITED_CHANGE_TYPES" -- . "${EXCLUDED_PATHSPECS[@]}" 2>/dev/null)
if [ -z "$staged_diff" ]; then
  # 監査する差分が空の記録が無いと、監査が動かなかったのか差分が無かったのかをログから見分けられないため、差分が空でも記録する。
  log_audit_entry "allow_no_diff" "$repo_name" '[]' || fail_closed "監査ログ (${AUDIT_LOG_FILE}) を書けない。"
  record_pass
  exit 0
fi

extra_docs=()
while IFS= read -r doc; do
  [ -z "$doc" ] && continue
  [ -f "${expected_repo_root}/${doc}" ] || fail_closed "リポジトリ ${repo_name} の前提ドキュメント ${doc} が見つからない。"
  extra_docs+=("$doc")
done < <(jq -r '(.extra_docs // [])[]' "$config_file")

auto_refs=$(kn_auto_inject_refs "$BASE_RULES" "${BASE_RULES}/principles.md") \
  || fail_closed 'principles.md が参照する base ルールの自動導出に失敗。'
auto_refs_json=$(printf '%s\n' "$auto_refs" | jq -R . | jq -sc 'map(select(length > 0))')
staged_names_json=$(kn_list_staged_files "$KN_AUDITED_CHANGE_TYPES" . "${EXCLUDED_PATHSPECS[@]}" 2>/dev/null | jq -R . | jq -sc 'map(select(length > 0))')

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

mkdir -p "$AUDITOR_WORK_DIR" || fail_closed "auditor の作業ディレクトリ (${AUDITOR_WORK_DIR}) を作れない。"
state_file="$(git rev-parse --path-format=absolute --git-dir)/${AUDITOR_STATE_FILE_NAME}" || fail_closed 'commit 先の git ディレクトリを求められない。'
# コミットが 1 つも無いリポジトリも審査できるようにするため、HEAD が無いときは空文字として扱う。
head_commit=$(git rev-parse --verify --quiet HEAD)
staged_tree=$(kn_write_staged_tree) || fail_closed 'ステージ内容のツリーを作れない。'

auditors='[]'
if [ -f "$state_file" ]; then
  previous_state=$(jq -ce 'select((.head | type == "string") and (.tree | type == "string") and (.auditors | type == "array"))' "$state_file") \
    || fail_closed "前回の審査の記録 (${state_file}) が壊れている。削除してから commit してください。"
  # コミットが作られたあとにステージした差分は別の変更のため、HEAD が前回の審査のときと同じ場合だけ、前回の監査の Claude に続きを審査させる。
  if [ "$(printf '%s' "$previous_state" | jq -r '.head')" = "$head_commit" ]; then
    auditors=$(printf '%s' "$previous_state" | jq -c '.auditors')
    re_audit_changes "$(printf '%s' "$previous_state" | jq -r '.tree')"
  fi
fi
audit_unassigned_files
save_auditor_state
all_violations=$(printf '%s' "$auditors" | jq -c '[.[].violations[]]') || fail_closed "審査の記録 (${state_file}) から違反を取り出せない。削除してから commit してください。"

violations_count=$(printf '%s' "$all_violations" | jq 'length')
if [ "$violations_count" -eq 0 ]; then
  # 違反なしの記録が無いと、監査が動かなかったのか違反が 0 件だったのかをログから見分けられないため、違反なしでも記録する。
  log_audit_entry "allow" "$repo_name" "$all_violations" || fail_closed "監査ログ (${AUDIT_LOG_FILE}) を書けない。"
  record_pass
  exit 0
fi

autofix=$(printf '%s' "$all_violations" | jq -c "${VIOLATION_JQ_DEFINITIONS}"' [.[] | select(is_autofix)]')
escalate=$(printf '%s' "$all_violations" | jq -c "${VIOLATION_JQ_DEFINITIONS}"' [.[] | select(is_autofix | not)]')
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

# 確認ダイアログは長い理由の後半を省略するため、行動・ログの場所・指摘ごとの 1 行の一覧を詳細より前に出す。
reason=$(
  printf '修正するなら拒否、意図的に commit するなら許可してください。\n全文: %s\n\n判断を要するルール違反 %d 件:\n' "$AUDIT_LOG_FILE" "$escalate_count"
  printf '%s' "$escalate" | format_violation_summary
  printf '\n\n'
  printf '%s' "$escalate" | format_violations
)
record_pass
emit_decision "ask" "$reason"
