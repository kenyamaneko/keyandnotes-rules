#!/usr/bin/env bash
# 検査を通っていない報告が出たときに差し戻せるよう、応答の完了時に報告を別プロセスの Claude に判定させ、違反があれば差し戻す。
# 草稿の検査 (check-report.sh) を通った報告は、同じ判定の繰り返しを避けるため検査せずに通す。
# Stop から呼ばれ、stdin の JSON を受け取る。差し戻しは decision=block の JSON で出力する。

set -uo pipefail

readonly MAX_BLOCKS_PER_PROMPT=5

# shellcheck source=report-review-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/report-review-common.sh"

emit_block() {
  local reason="$1" session_id="$2" prompt_id="$3"
  mkdir -p "$READ_LOG_DIR"
  printf '%s\n' "$prompt_id" >> "${READ_LOG_DIR}/${session_id}.blocks"
  jq -nc --arg reason "$reason" '{decision: "block", reason: $reason}'
}

main() {
  # 子プロセスの Claude が同じ Stop フックを再び起動して無限に再帰するのを防ぐため、子プロセスでは何もしない。
  if [ -n "${!CHILD_GUARD_ENV:-}" ]; then
    return 0
  fi

  local input message session_id prompt_id
  input=$(cat)
  message=$(printf '%s' "$input" | jq -r '.last_assistant_message')

  if ! is_report_message "$message"; then
    return 0
  fi

  session_id=$(printf '%s' "$input" | jq -r '.session_id')
  prompt_id=$(printf '%s' "$input" | jq -r '.prompt_id')

  if is_passed_message "$session_id" "$(hash_message "$message")"; then
    return 0
  fi

  # 差し戻し後の直し漏れを通すより、検査の失敗や Read の記録漏れで差し戻しが終わらず費用が増え続けるほうが害が大きいため、同じユーザー入力への差し戻しに上限を置く。
  if [ "$(count_lines_in_log "${READ_LOG_DIR}/${session_id}.blocks" "$prompt_id")" -ge "$MAX_BLOCKS_PER_PROMPT" ]; then
    return 0
  fi

  local reasons review_status error_file
  error_file=$(mktemp)
  reasons=$(review_message "$message" "$session_id" "$prompt_id" 2>"$error_file")
  review_status=$?

  if [ "$review_status" -ne 0 ]; then
    emit_block "$(cat "$error_file")" "$session_id" "$prompt_id"
    rm -f "$error_file"
    return 0
  fi
  rm -f "$error_file"

  if [ -z "$reasons" ]; then
    return 0
  fi

  emit_block "報告の検査で次を指摘された。直してから報告を書き直す。

${reasons}" "$session_id" "$prompt_id"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
  exit 0
fi
