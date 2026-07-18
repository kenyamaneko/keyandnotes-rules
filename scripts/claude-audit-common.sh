#!/usr/bin/env bash
# pre-commit SOFT audit hook (各リポの .claude/scripts/pre-commit-claude-audit.sh) から source される
# 共有ロジック。principles.md が @import する base ルールを動的に導出し注入することで、
# 「auditor に注入するルール一覧」を手書きリストとして各リポが個別に持つ二重管理を排除する。
#
# 不変条件: principles.md が @import する全ファイルは、監査対象リポの hook で注入されるか、
# さもなくば commit を fail-close する。

# principles.md (絶対パス) が @import する参照先の相対パスを、重複なく1行1件で返す。
kn_discover_base_refs() {
  local principles_path="$1"
  grep -oE '@[A-Za-z0-9_./-]+\.md' "$principles_path" | sed 's/^@//' | sort -u
}

# kn_discover_base_refs の結果から、呼び出し側が明示的に扱っている参照 (第3引数以降) を除いた
# 「自動注入すべき base-only ルール名」を1行1件で返す。
# 除外対象は、diff の内容によって適用要否が変わる正当な条件分岐を呼び出し側が既に持つ参照
# (例: testing.md) に限る。principles_path が存在しない、または参照先ファイルが base_rules_dir に
# 実在しない場合は stderr にエラーを出し、fail-closed のため非ゼロで終了する。
kn_auto_inject_refs() {
  local base_rules_dir="$1" principles_path="$2"
  shift 2
  local exclude_refs=("$@")
  local ref path skip ex missing=0

  if [ ! -f "$principles_path" ]; then
    printf 'kn_auto_inject_refs: principles.md (%s) が見つかりません。\n' "$principles_path" >&2
    return 2
  fi

  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    skip=0
    for ex in "${exclude_refs[@]}"; do
      [ "$ex" = "$ref" ] && { skip=1; break; }
    done
    [ "$skip" -eq 1 ] && continue

    path="${base_rules_dir}/${ref}"
    if [ ! -f "$path" ]; then
      printf 'kn_auto_inject_refs: principles.md が参照する %s が %s に見つかりません。\n' "$ref" "$path" >&2
      missing=1
      continue
    fi
    printf '%s\n' "$ref"
  done < <(kn_discover_base_refs "$principles_path")

  [ "$missing" -eq 1 ] && return 2
  return 0
}
