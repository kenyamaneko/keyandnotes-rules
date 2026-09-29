#!/usr/bin/env bash
# 先頭で読み込んだルールへの注意は数回のやりとりで薄れるため、ユーザーの発言のたびに読み直しを促し、対話方法の節は本文を添える。
# UserPromptSubmit から呼ばれ、additionalContext を出力する。

set -uo pipefail

readonly DIALOGUE_HEADING='## [base] ユーザーへの報告と質問'

rules_dir="$(cd "$(dirname "$0")/.." && pwd)/rules"
principles_file="${rules_dir}/principles.md"

dialogue_section=$(awk -v heading="$DIALOGUE_HEADING" '
  $0 == heading { in_section = 1; print; next }
  in_section && /^## / { exit }
  in_section { print }
' "$principles_file" 2>/dev/null)

if [ -z "$dialogue_section" ]; then
  dialogue_section="${principles_file} に見出し「${DIALOGUE_HEADING}」が見つからない。ユーザーにフックの見出し指定の更新が必要だと伝える。"
fi

message="${rules_dir} のうち、次の作業に関係するファイルを Read で読み直してから着手する。
ユーザーへの応答は次のルールに従う。

${dialogue_section}"
jq -nc --arg m "$message" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $m}}'

exit 0
