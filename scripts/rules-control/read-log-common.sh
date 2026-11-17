#!/usr/bin/env bash
# 現在のユーザー入力の ID を、記録する側 (remind-rules-reread.sh・record-current-prompt.sh) と読む側 (report-review-common.sh・check-report.sh) が同じ場所で読み書きするため、記録の場所と読み書きをまとめる。
# それらのスクリプトと record-rules-read.sh から source される。

readonly READ_LOG_DIR="${HOME}/.claude/kn-read-log"

# 現在のユーザー入力の ID を記録する。セッションの ID かユーザー入力の ID が空なら、記録できないことを標準エラー出力に出して 1 を返す。
record_current_prompt_id() {
  local session_id="$1" prompt_id="$2"
  if [ -z "$session_id" ] || [ -z "$prompt_id" ]; then
    printf '現在のユーザー入力の ID を記録できない。フックの入力にセッションの ID かユーザー入力の ID が無い。\n' >&2
    return 1
  fi
  mkdir -p "$READ_LOG_DIR"
  printf '%s\n' "$prompt_id" > "${READ_LOG_DIR}/${session_id}.prompt"
}

# 記録した現在のユーザー入力の ID を返す。記録が無ければ何も返さない。
read_current_prompt_id() {
  local session_id="$1"
  cat "${READ_LOG_DIR}/${session_id}.prompt" 2>/dev/null
}
