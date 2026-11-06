# keyandnotes-rules

Key and Notes 各プロジェクトの CLAUDE.md が `@import` で参照する共通開発ルール。Claude Code が実行することを前提に書く。

## フックの登録

次のコマンドで、このリポのフックを `~/.claude/settings.json` に登録する。

```sh
make setup-hooks
```

登録するフックは、リポごとの設定を持たず、commit 前の監査・`rules/` 配下の編集の確認・報告の検査などを全リポに適用する。

## commit 前の監査の対象リポ

commit 前の監査(`pre-commit-claude-audit.sh`)は、全リポの設定を `scripts/audit-repos.json` から引く。リポを作ったら、`repos` にそのリポの名前で次のいずれかを足す。

- 監査する: `overlay_dir`・`extra_docs`・`rules`・`exempt_overlays`・`exclude_pathspecs` を書く
- 監査しない: `{"excluded": true}` と書く

設定が無いリポで commit すると、監査不能として止まる。
