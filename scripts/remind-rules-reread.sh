#!/usr/bin/env bash
# 先頭で読み込んだルールへの注意は数回のやりとりで薄れるため、ユーザーの発言のたびに読み直しを促し、対話方法の節は本文と報告の雛形を添える。
# UserPromptSubmit から呼ばれ、additionalContext を出力する。

set -uo pipefail

readonly DIALOGUE_HEADING='## [base] ユーザーへの報告と質問'

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
rules_dir="${repo_dir}/rules"
principles_file="${rules_dir}/principles.md"
report_template_file="${repo_dir}/templates/report.template.md"

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

message="${rules_dir} のうち、次の作業に関係するファイルを Read で読み直してから着手する。
ユーザーへの応答は次のルールと雛形に従う。

${dialogue_section}

報告の雛形:

${report_template}"
jq -nc --arg m "$message" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $m}}'

exit 0
