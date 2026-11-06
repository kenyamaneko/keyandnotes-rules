# keyandnotes-rules

Key and Notes 各プロジェクトの CLAUDE.md が `@import` で参照する共通開発ルール。Claude Code が実行することを前提に書く。

## フックの登録

次のコマンドで、このリポのフックを `~/.claude/settings.json` に登録する。2 回目以降は、このリポのスクリプトを指す登録を現在の内容で置き換える。リポを更新したあとにもう一度実行すれば、フックの追加・変更・削除が設定に反映される。

```sh
make setup-hooks
```

| フック | 内容 |
|---|---|
| `scripts/remind-rules-reread.sh` | ユーザーの入力ごとに、ルールの読み直しと報告の雛形を Claude に伝える |
| `scripts/review-report.sh` | 応答の完了時に、報告を別プロセスの Claude に検査させ、違反があれば差し戻す |
| `scripts/record-rules-read.sh` | Read したファイルを記録し、`review-report.sh` がルールを読んだかの確認に使う |