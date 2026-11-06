#!/usr/bin/env bash
# Stop フック (review-report.sh) が、ルールを読んだかをユーザー入力ごとに確かめられるように、Read したファイルを記録する。
# PostToolUse (Read matcher) から呼ばれ、stdin の JSON を受け取る。

set -uo pipefail

readonly READ_LOG_DIR="${HOME}/.claude/kn-read-log"

input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id')
prompt_id=$(printf '%s' "$input" | jq -r '.prompt_id')
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path')

mkdir -p "$READ_LOG_DIR"
printf '%s\t%s\n' "$prompt_id" "$file_path" >> "${READ_LOG_DIR}/${session_id}.tsv"

exit 0
