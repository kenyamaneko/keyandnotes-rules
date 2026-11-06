#!/usr/bin/env bash
# rules/ 配下は原則として人間が運用する。Claude Code の Edit / Write は明示許可があるときのみ許す。
# PreToolUse (Edit|Write matcher) から stdin 経由で JSON を受け取り、対象が rules/ 配下なら
# permissionDecision=ask で user に確認を促す。人間が直接編集する場合は本 hook を通らない。

set -uo pipefail

input=$(cat)
if [ -z "$input" ]; then
  exit 0
fi

fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)

case "$fp" in
  rules/*|*/rules/*)
    reason='rules/ 配下は原則として人間が運用するファイルです。編集は明示的な許可があるときのみ行ってください。'
    jq -nc --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
    ;;
esac

exit 0
