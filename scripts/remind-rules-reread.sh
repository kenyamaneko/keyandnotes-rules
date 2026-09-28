#!/usr/bin/env bash
# 長いセッションでは先頭で読み込んだルールへの注意が薄れるため、ユーザーの発言が一定回数に達するたびに読み直しを促す。
# UserPromptSubmit から stdin 経由で JSON を受け取り、session_id ごとに発言回数を数える。

set -uo pipefail

readonly REMIND_INTERVAL=10

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)
if [ -z "$session_id" ]; then
  exit 0
fi

counter_dir="${TMPDIR:-/tmp}/claude-rules-reread"
mkdir -p "$counter_dir"
counter_file="${counter_dir}/${session_id}"

count=$(cat "$counter_file" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"

if [ $((count % REMIND_INTERVAL)) -ne 0 ]; then
  exit 0
fi

rules_dir="$(cd "$(dirname "$0")/.." && pwd)/rules"
message="${rules_dir} のうち、次の作業に関係するファイルを Read で読み直してから着手する。"
jq -nc --arg m "$message" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $m}}'

exit 0
