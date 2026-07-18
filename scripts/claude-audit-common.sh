#!/usr/bin/env bash
# pre-commit SOFT audit hook (各リポの .claude/scripts/pre-commit-claude-audit.sh) から source される。
# principles.md の @import 一覧を手書きで複製すると更新に追従しない二重管理になるため、動的に導出する。

# principles.md が @import する参照先を1行1件で返す。
kn_discover_base_refs() {
  local principles_path="$1"
  grep -oE '@[A-Za-z0-9_./-]+\.md' "$principles_path" | sed 's/^@//' | sort -u
}

# kn_discover_base_refs の結果から exclude_refs (呼び出し側が別途扱う参照) を除いた注入対象を返す。
# principles_path または参照先ファイルが存在しない場合は fail-closed で非ゼロ終了する。
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
