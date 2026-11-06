#!/usr/bin/env bash
# 検査を通っていない報告をユーザーに見せないため、応答を最後まで受けてから検査し、通った報告だけを画面に出す。
# MessageDisplay から呼ばれ、stdin の JSON を受け取る。画面に出す文面を displayContent で出力する。何も出力しないと、元の文面が画面に出る。

set -uo pipefail

# shellcheck source=report-review-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/report-review-common.sh"

readonly MAX_HIDDEN_PER_PROMPT=5
readonly HIDDEN_NOTICE='(報告の検査で差し戻したため、この報告は表示しない)'
readonly BUFFER_DIR="${READ_LOG_DIR}/display"

emit_display() {
  jq -nc --rawfile text /dev/stdin '{hookSpecificOutput: {hookEventName: "MessageDisplay", displayContent: $text}}'
}

main() {
  # 子プロセスの Claude の応答は検査の対象ではないため、何もしない。
  if [ -n "${!CHILD_GUARD_ENV:-}" ]; then
    return 0
  fi

  local input session_id message_id is_final buffer_file
  input=$(cat)
  session_id=$(printf '%s' "$input" | jq -r '.session_id')
  message_id=$(printf '%s' "$input" | jq -r '.message_id')
  is_final=$(printf '%s' "$input" | jq -r '.final')

  mkdir -p "$BUFFER_DIR"
  buffer_file="${BUFFER_DIR}/${session_id}.${message_id}"
  printf '%s' "$input" | jq -j '.delta' >> "$buffer_file"

  if [ "$is_final" != "true" ]; then
    printf '' | emit_display
    return 0
  fi

  local message message_hash prompt_id reasons review_status error_file
  message=$(cat "$buffer_file")
  message_hash=$(hash_message "$message")

  if ! is_report_message "$message" || is_passed_message "$session_id" "$message_hash"; then
    emit_display < "$buffer_file"
    rm -f "$buffer_file"
    return 0
  fi

  prompt_id=$(cat "${READ_LOG_DIR}/${session_id}.prompt" 2>/dev/null)

  # 差し戻しの上限に達した後は Stop フックが差し戻さないため、報告を隠したままにせず画面に出す。
  if [ "$(count_lines_in_log "${READ_LOG_DIR}/${session_id}.blocks" "$prompt_id")" -ge "$MAX_HIDDEN_PER_PROMPT" ]; then
    emit_display < "$buffer_file"
    rm -f "$buffer_file"
    return 0
  fi

  error_file=$(mktemp)
  reasons=$(review_message "$message" "$session_id" "$prompt_id" 2>"$error_file")
  review_status=$?
  rm -f "$error_file"

  if [ "$review_status" -ne 0 ]; then
    emit_display < "$buffer_file"
  elif [ -z "$reasons" ]; then
    record_passed_message "$session_id" "$message_hash"
    emit_display < "$buffer_file"
  else
    save_review_reasons "$session_id" "$message_hash" "$reasons"
    printf '%s' "$HIDDEN_NOTICE" | emit_display
  fi
  rm -f "$buffer_file"
}

main
exit 0
