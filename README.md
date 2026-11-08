# keyandnotes-rules

Key and Notes 各プロジェクトの CLAUDE.md が `@import` で参照する共通開発ルール。Claude Code が実行することを前提に書く。

## フックの登録

次のコマンドで、このリポのフックを `~/.claude/settings.json` に登録する。

```sh
make setup-hooks
```

## コミット前の監査の対象リポ

コミット前の監査 (`scripts/commit-audit`) は、監査するリポを `scripts/commit-audit/config/audit-repos.yaml` から読む。このファイルは git で管理しないため、雛形をコピーして自分のリポに合わせて書き換える。ファイルが無いと、すべてのリポのコミットが止まる。

```sh
cp scripts/commit-audit/config/audit-repos.template.yaml scripts/commit-audit/config/audit-repos.yaml
```
