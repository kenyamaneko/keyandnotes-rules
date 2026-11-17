#!/usr/bin/env bash
# 実行中のターンに後から送られたユーザー入力は、UserPromptSubmit に前のターンの ID が渡されて ID の記録が古くなるため、ツールを実行する直前にも現在のユーザー入力の ID を記録する。
# PreToolUse (Bash matcher) から呼ばれ、stdin の JSON を受け取る。

set -uo pipefail

readonly READ_LOG_DIR="${HOME}/.claude/kn-read-log"

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
prompt_id=$(printf '%s' "$input" | jq -r '.prompt_id // empty')

if [ -n "$session_id" ] && [ -n "$prompt_id" ]; then
  mkdir -p "$READ_LOG_DIR"
  printf '%s\n' "$prompt_id" > "${READ_LOG_DIR}/${session_id}.prompt"
fi

exit 0
