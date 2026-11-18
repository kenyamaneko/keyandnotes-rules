#!/usr/bin/env bash
# 検査を通っていない報告をユーザーに見せないため、応答を最後まで受けてから判定し、検査を通った報告だけを画面に出す。
# MessageDisplay から呼ばれ、stdin の JSON を受け取る。画面に出す文面を displayContent で出力する。何も出力しないと、元の文面が画面に出る。

set -uo pipefail

readonly HIDDEN_NOTICE='(報告の検査で差し戻したため、この報告は表示しない)'

# shellcheck source=report-review-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/report-review-common.sh"

readonly BUFFER_DIR="${READ_LOG_DIR}/display"

emit_display() {
  jq -nc --rawfile text /dev/stdin '{hookSpecificOutput: {hookEventName: "MessageDisplay", displayContent: $text}}'
}

main() {
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

  local message prompt_id
  message=$(cat "$buffer_file")
  prompt_id=$(read_current_prompt_id "$session_id")

  if should_hold_message "$message" "$session_id" "$prompt_id"; then
    record_held_prompt "$session_id" "$prompt_id" "$message"
    # Stop フックの差し戻し理由の表示は隠せず、隠せるのは報告の本文だけのため、報告だけを画面から隠す。
    printf '%s' "$HIDDEN_NOTICE" | emit_display
  elif is_report_message "$message"; then
    clear_held_prompt "$session_id"
    if is_passed_message "$session_id" "$(hash_message "$message")"; then
      emit_display < "$buffer_file"
    else
      { printf '%s\n\n' "$UNCHECKED_REPORT_NOTICE"; cat "$buffer_file"; } | emit_display
    fi
  else
    emit_display < "$buffer_file"
  fi
  rm -f "$buffer_file"
}

main
exit 0
