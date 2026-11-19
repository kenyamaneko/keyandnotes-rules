#!/usr/bin/env bash
# 検査を通っていない報告をユーザーに見せないため、応答を最後まで受けてから判定し、検査を通った報告だけを画面に出す。
# MessageDisplay から呼ばれ、stdin の JSON を受け取る。画面に出す文面を displayContent で出力する。何も出力しないと、元の文面が画面に出る。

set -uo pipefail

readonly HIDDEN_NOTICE='(報告の検査で差し戻したため、この報告は表示しない)'

# shellcheck source=report-review-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/report-review-common.sh"

readonly BUFFER_DIR="${READ_LOG_DIR}/display"
readonly BATCH_WAIT_LIMIT_MS=5000
readonly BATCH_POLL_INTERVAL_SECONDS=0.05
readonly BATCH_POLL_INTERVAL_MS=50

emit_display() {
  jq -nc --rawfile text /dev/stdin '{hookSpecificOutput: {hookEventName: "MessageDisplay", displayContent: $text}}'
}

# 同じメッセージの断片ごとのフックは並行して起動され、最後の断片のフックが先の断片より先に動くことがあるため、断片を番号つきのファイルに分けて保存する。
save_batch() {
  local batch_prefix="$1" batch_index="$2" input="$3"
  printf '%s' "$input" | jq -j '.delta' > "${batch_prefix}.${batch_index}.partial"
  mv "${batch_prefix}.${batch_index}.partial" "${batch_prefix}.${batch_index}"
}

# 最後の断片のフックが先の断片のフックの保存より先に動いても全文を組み立てるため、最後の断片の番号までの断片がそろうのを待つ。
wait_for_batches() {
  local batch_prefix="$1" last_index="$2" waited_ms=0 batch_index missing
  while :; do
    missing=false
    for ((batch_index = 0; batch_index <= last_index; batch_index++)); do
      [ -f "${batch_prefix}.${batch_index}" ] || { missing=true; break; }
    done
    [ "$missing" = false ] && return 0
    [ "$waited_ms" -ge "$BATCH_WAIT_LIMIT_MS" ] && return 1
    sleep "$BATCH_POLL_INTERVAL_SECONDS"
    waited_ms=$((waited_ms + BATCH_POLL_INTERVAL_MS))
  done
}

assemble_batches() {
  local batch_prefix="$1" last_index="$2" batch_index
  for ((batch_index = 0; batch_index <= last_index; batch_index++)); do
    cat "${batch_prefix}.${batch_index}"
  done
}

main() {
  local input session_id message_id batch_index is_final batch_prefix
  input=$(cat)
  session_id=$(printf '%s' "$input" | jq -r '.session_id')
  message_id=$(printf '%s' "$input" | jq -r '.message_id')
  batch_index=$(printf '%s' "$input" | jq -r '.index')
  is_final=$(printf '%s' "$input" | jq -r '.final')

  mkdir -p "$BUFFER_DIR"
  batch_prefix="${BUFFER_DIR}/${session_id}.${message_id}"
  save_batch "$batch_prefix" "$batch_index" "$input"

  if [ "$is_final" != "true" ]; then
    printf '' | emit_display
    return 0
  fi

  if ! wait_for_batches "$batch_prefix" "$batch_index"; then
    printf '同じメッセージの断片がそろわなかったため、報告の検査の判定ができない。元の文面をそのまま表示する。\n' >&2
    rm -f "${batch_prefix}".*
    return 1
  fi

  local message prompt_id assembled_file="${batch_prefix}.assembled"
  assemble_batches "$batch_prefix" "$batch_index" > "$assembled_file"
  message=$(cat "$assembled_file")
  prompt_id=$(read_current_prompt_id "$session_id")

  if should_hold_message "$message" "$session_id" "$prompt_id"; then
    record_held_prompt "$session_id" "$prompt_id" "$message"
    # Stop フックの差し戻し理由の表示は隠せず、隠せるのは報告の本文だけのため、報告だけを画面から隠す。
    printf '%s' "$HIDDEN_NOTICE" | emit_display
  elif is_report_message "$message"; then
    clear_held_prompt "$session_id"
    if is_passed_message "$session_id" "$(hash_message "$message")"; then
      emit_display < "$assembled_file"
    else
      format_unchecked_report "$message" | emit_display
    fi
  else
    emit_display < "$assembled_file"
  fi
  rm -f "${batch_prefix}".*
}

main
exit 0
