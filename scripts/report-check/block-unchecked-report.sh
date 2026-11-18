#!/usr/bin/env bash
# 検査を通っていない報告が画面に出なかったままターンが終わらないよう、画面から隠した報告があるあいだ、報告の書き直しを求めて差し戻す。
# 隠したのに差し戻さない状態を作らないため、隠す条件は hold-unchecked-report.sh と同じ判定 (should_hold_message) を使う。
# Stop から呼ばれ、stdin の JSON を受け取る。差し戻しは decision=block の JSON で、保存した報告の表示は systemMessage の JSON で出力する。

set -uo pipefail

# shellcheck source=report-review-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/report-review-common.sh"

emit_block() {
  local session_id="$1" prompt_id="$2"
  mkdir -p "$READ_LOG_DIR"
  printf '%s\n' "$prompt_id" >> "${READ_LOG_DIR}/${session_id}.blocks"
  jq -nc --arg reason "報告が検査を通っていないため、画面に出ていない。応答の全文を草稿のファイルに書き、${repo_dir}/scripts/report-check/check-report.sh に草稿のファイルを渡して実行する。依頼事項に報告用の HTML の場所を書くときは、その HTML のファイルも 2 つ目の引数に渡す。違反が出たら草稿を直して通るまで繰り返し、通ったら草稿の全文をそのまま最終の応答として出す。" \
    '{decision: "block", reason: $reason}'
}

emit_held_report() {
  local session_id="$1" report
  report=$(read_held_report "$session_id") || {
    printf '隠した報告の全文の記録を読めない。報告が画面に出ていないため、報告の依頼事項に、記録を保存する処理 (hold-unchecked-report.sh) の修正を書く。\n' >&2
    return 1
  }
  jq -nc --arg text "$(format_unchecked_report "$report")" '{systemMessage: $text}'
  clear_held_prompt "$session_id"
}

main() {
  local input message session_id prompt_id
  input=$(cat)
  message=$(printf '%s' "$input" | jq -r '.last_assistant_message')
  session_id=$(printf '%s' "$input" | jq -r '.session_id')
  prompt_id=$(read_current_prompt_id "$session_id")

  if should_hold_message "$message" "$session_id" "$prompt_id"; then
    emit_block "$session_id" "$prompt_id"
    return 0
  fi

  # 画面に出た報告が、隠した記録の削除より先に判定されても差し戻さないため、検査を通った報告では差し戻さない。
  if is_passed_message "$session_id" "$(hash_message "$message")"; then
    return 0
  fi

  is_prompt_held "$session_id" "$prompt_id" || return 0

  if has_blocks_remaining "$session_id" "$prompt_id" && ! has_check_failure "$session_id" "$prompt_id"; then
    emit_block "$session_id" "$prompt_id"
  else
    emit_held_report "$session_id"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
  exit 0
fi
