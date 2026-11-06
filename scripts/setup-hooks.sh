#!/usr/bin/env bash
# このリポのフックを Claude Code の設定ファイル (既定は ~/.claude/settings.json) に登録する。

set -euo pipefail

readonly DEFAULT_SETTINGS_FILE="${HOME}/.claude/settings.json"
readonly REVIEW_REPORT_TIMEOUT_SECONDS=180

# worktree から実行しても、worktree を消したときにフックが壊れないよう、登録するパスは本体のチェックアウトにする。
git_common_dir="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --path-format=absolute --git-common-dir)"
scripts_dir="$(dirname "$git_common_dir")/scripts"
settings_file="${1:-$DEFAULT_SETTINGS_FILE}"

mkdir -p "$(dirname "$settings_file")"
[ -f "$settings_file" ] || printf '{}\n' > "$settings_file"

# スクリプトの変更を取り込めるよう、2 回目以降の実行では上書きする。
registered=$(jq \
  --arg dir "${scripts_dir}/" \
  --arg remind "${scripts_dir}/remind-rules-reread.sh" \
  --arg review "${scripts_dir}/review-report.sh" \
  --arg record "${scripts_dir}/record-rules-read.sh" \
  --arg guard "${scripts_dir}/guard-rules-edit.sh" \
  --arg machine_audit "${scripts_dir}/pre-commit-machine-audit.sh" \
  --arg claude_audit "${scripts_dir}/pre-commit-claude-audit.sh" \
  --arg hold "${scripts_dir}/hold-unchecked-report.sh" \
  --argjson review_timeout "$REVIEW_REPORT_TIMEOUT_SECONDS" '
  def register($event; $entry):
    .hooks[$event] = ((.hooks[$event] // []) + [$entry]);
  .hooks = (
    (.hooks // {})
    | map_values(map(.hooks |= map(select((.command // "") | startswith($dir) | not))) | map(select(.hooks | length > 0)))
    | with_entries(select(.value | length > 0)))
  | register("UserPromptSubmit"; {hooks: [{type: "command", command: $remind}]})
  | register("Stop"; {hooks: [{type: "command", command: $review, timeout: $review_timeout}]})
  | register("MessageDisplay"; {hooks: [{type: "command", command: $hold, timeout: $review_timeout}]})
  | register("PostToolUse"; {matcher: "Read", hooks: [{type: "command", command: $record}]})
  | register("PreToolUse"; {matcher: "Edit|Write", hooks: [{type: "command", command: $guard}]})
  | register("PreToolUse"; {matcher: "Bash", hooks: [{type: "command", command: $machine_audit}, {type: "command", command: $claude_audit}]})
' "$settings_file")

printf '%s\n' "$registered" > "$settings_file"
printf 'フックを登録した: %s\n' "$settings_file"
