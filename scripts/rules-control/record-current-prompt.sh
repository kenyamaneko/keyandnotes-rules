#!/usr/bin/env bash
# 実行中のターンに後から送られたユーザー入力は、UserPromptSubmit に前のターンの ID が渡されて ID の記録が古くなるため、ツールを実行する直前にも現在のユーザー入力の ID を記録する。
# PreToolUse (Bash matcher) から呼ばれ、stdin の JSON を受け取る。

set -uo pipefail

# shellcheck source=read-log-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/read-log-common.sh"

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
prompt_id=$(printf '%s' "$input" | jq -r '.prompt_id // empty')

record_current_prompt_id "$session_id" "$prompt_id"
