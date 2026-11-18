#!/usr/bin/env bash
# 現在のユーザー入力の ID を、どのスクリプトも同じ方法で読むため、読み方と記録の場所をまとめる。

readonly READ_LOG_DIR="${HOME}/.claude/kn-read-log"
readonly CLAUDE_PROJECTS_DIR="${HOME}/.claude/projects"
readonly HUMAN_ENTRY_MARKER='"origin":{"kind":"human"'

# 現在のユーザー入力の ID として、会話の記録ファイルの最後の、人が送った発言の uuid を返す。
# 人が送った発言とは、発言の送り手の種類 (origin.kind) が human のエントリを指す。ツールの結果・フックの差し戻し・バックグラウンド作業の通知は含まない。
read_current_prompt_id() {
  local session_id="$1" transcript_file
  transcript_file=$(ls "${CLAUDE_PROJECTS_DIR}"/*/"${session_id}.jsonl" 2>/dev/null | head -n 1)
  grep -F -- "$HUMAN_ENTRY_MARKER" "$transcript_file" | tail -n 1 | jq -r '.uuid'
}
