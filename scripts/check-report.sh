#!/usr/bin/env bash
# 差し戻しの再報告をユーザーに見せないため、応答を出す前に報告の草稿を検査する。
# 使い方: check-report.sh <草稿のファイル>。草稿には最終の応答の全文を書く。
# 通れば、草稿の記録を残して 0 を返す。違反があれば指摘を出して 1、検査の失敗や前提の欠落は 2 を返す。

set -uo pipefail

readonly MAX_CHECKS_PER_PROMPT=10
readonly STATUS_VIOLATION=1
readonly STATUS_FAILURE=2

# shellcheck source=report-review-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/report-review-common.sh"

main() {
  local draft_file="${1:-}"
  if [ -z "$draft_file" ] || [ ! -f "$draft_file" ]; then
    printf '使い方: check-report.sh <草稿のファイル>\n' >&2
    return "$STATUS_FAILURE"
  fi

  local session_id="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -z "$session_id" ]; then
    printf '環境変数 CLAUDE_CODE_SESSION_ID が無い。報告の依頼事項に、検査コマンド (check-report.sh) の修正を書く。\n' >&2
    return "$STATUS_FAILURE"
  fi

  local prompt_file="${READ_LOG_DIR}/${session_id}.prompt" prompt_id
  prompt_id=$(cat "$prompt_file" 2>/dev/null)
  if [ -z "$prompt_id" ]; then
    printf '現在のユーザー入力の ID が記録されていない (%s)。報告の依頼事項に、UserPromptSubmit フック (remind-rules-reread.sh) の修正を書く。\n' "$prompt_file" >&2
    return "$STATUS_FAILURE"
  fi

  # 検査の失敗が続いたときに費用が増え続けるのを防ぐため、同じユーザー入力への検査に上限を置く。
  local checks_file="${READ_LOG_DIR}/${session_id}.checks"
  if [ "$(count_lines_in_log "$checks_file" "$prompt_id")" -ge "$MAX_CHECKS_PER_PROMPT" ]; then
    printf '同じユーザー入力への検査が上限 (%s 回) に達した。報告の依頼事項に、検査が通らない原因を書く。\n' "$MAX_CHECKS_PER_PROMPT" >&2
    return "$STATUS_FAILURE"
  fi
  mkdir -p "$READ_LOG_DIR"
  printf '%s\n' "$prompt_id" >> "$checks_file"

  local message reasons review_status
  message=$(cat "$draft_file")

  if ! is_report_message "$message"; then
    printf '草稿に「%s」の見出しも判断事項の項目も無い。報告を含む応答の全文を草稿に書く。\n' "$REPORT_HEADING" >&2
    return "$STATUS_FAILURE"
  fi

  reasons=$(review_message "$message" "$session_id" "$prompt_id")
  review_status=$?
  if [ "$review_status" -ne 0 ]; then
    return "$STATUS_FAILURE"
  fi

  if [ -n "$reasons" ]; then
    printf '報告の検査で次を指摘された。直してから、もう一度検査する。\n\n%s' "$reasons"
    return "$STATUS_VIOLATION"
  fi

  record_passed_message "$session_id" "$(hash_message "$message")"
  printf '検査を通った。草稿の全文を、そのまま最終の応答として出す。\n'
}

main "$@"
