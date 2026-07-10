> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

# Branching Strategy (GitHub Flow)

GitHub Flow を採用するリポのブランチ戦略。

## 概要

`main` を唯一の永続ブランチとし、短命の `feature/*` を切って PR で `main` へマージする。

## ブランチ一覧

| ブランチ | 寿命 | 派生元 | マージ先 | 保護 |
|---|---|---|---|---|
| `main` | 永続 | — | — | 最大 |
| `feature/xxx` | 短命 | `main` | `main` | なし |

## ブランチ運用ルール

### main

- **唯一の永続ブランチ**。常にデプロイ可能な状態を保つ
- 直 push 禁止。PR 経由のマージのみ
- force push 禁止、履歴書き換え禁止

### feature/xxx

- すべての変更 (新機能・バグ修正・リファクタ・ドキュメント) はこのブランチで行う
- `main` から切って `main` にマージ
- 命名: `feature/{issue番号}-{概要}` (例: `feature/42-add-foo`)
- 短命に保つ (目安: 数時間〜数日)。長期化する場合は分割を検討する
- PR マージ時にブランチ削除

## 通常フロー

```
1. feature ブランチを切る
   └─ git fetch origin && git switch -c feature/{n}-{summary} origin/main

2. 実装・コミット
   └─ ローカルでテスト・ビルド・lint を通す

3. push → PR
   └─ feature/xxx → main (PR)
   └─ CI green + レビュー OK 後にマージ

4. マージ後
   └─ feature ブランチ削除
```

## 緊急修正 (hotfix)

緊急修正も通常の feature と同じ扱いとし、急ぎでも PR を経由する。

## ブランチ保護設定

GitHub Rulesets で以下を設定する。必須ステータスチェックの具体名は各リポの CI/CD ドキュメントを参照。

### main

- 直 push 禁止
- PR マージのみ許可 (linear history)
- force push 禁止、削除禁止
- 履歴書き換え禁止
- 必須ステータスチェック: CI の lint / test (該当すれば plan) が green
- required reviews: 1 (一人開発リポでは self-approve 可で速度優先)
