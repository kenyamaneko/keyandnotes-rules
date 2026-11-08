#!/usr/bin/env bash
# 先頭で読み込んだルールへの注意は数回のやりとりで薄れるため、ユーザーの発言のたびに読み直しを促し、対話方法の節は本文と報告の雛形を添える。
# UserPromptSubmit から呼ばれ、additionalContext を出力する。

set -uo pipefail

readonly DIALOGUE_HEADING='## [base] ユーザーへの報告と質問'
readonly READ_LOG_DIR="${HOME}/.claude/kn-read-log"

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
rules_dir="${repo_dir}/rules"
principles_file="${rules_dir}/principles.md"
report_template_file="${repo_dir}/templates/report.template.md"

# 草稿の検査 (check-report.sh) が、ユーザー入力ごとの Read の記録と照らせるよう、現在のユーザー入力の ID を残す。
input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
prompt_id=$(printf '%s' "$input" | jq -r '.prompt_id // empty')
if [ -n "$session_id" ] && [ -n "$prompt_id" ]; then
  mkdir -p "$READ_LOG_DIR"
  printf '%s\n' "$prompt_id" > "${READ_LOG_DIR}/${session_id}.prompt"
fi

dialogue_section=$(awk -v heading="$DIALOGUE_HEADING" '
  $0 == heading { in_section = 1; print; next }
  in_section && /^## / { exit }
  in_section { print }
' "$principles_file" 2>/dev/null)

if [ -z "$dialogue_section" ]; then
  dialogue_section="${principles_file} に見出し「${DIALOGUE_HEADING}」が見つからない。ユーザーにフックの見出し指定の更新が必要だと伝える。"
fi

report_template=$(cat "$report_template_file" 2>/dev/null)

if [ -z "$report_template" ]; then
  report_template="${report_template_file} が読めない。ユーザーにフックの雛形指定の更新が必要だと伝える。"
fi

# 応答の本文を出す前に止めるフックが無く、草稿の検査を強制できないため、指示で依頼する。
message="${rules_dir} のうち、次の作業に関係するファイルを Read で読み直してから着手する。
ユーザーへの応答は次のルールと雛形に従う。

${dialogue_section}

報告の雛形:

${report_template}

報告 (「## 報告事項」の見出しか判断事項の項目を含む応答) を出す前に、応答の全文を草稿のファイルに書き、${repo_dir}/scripts/report-check/check-report.sh に草稿のファイルを渡して実行する。違反が出たら草稿を直して、通るまで繰り返す。通ったら、草稿の全文をそのまま最終の応答として出す。検査を通っていない報告を出すと、差し戻されて直した報告が画面に何度も出る。"
jq -nc --arg m "$message" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $m}}'

exit 0
