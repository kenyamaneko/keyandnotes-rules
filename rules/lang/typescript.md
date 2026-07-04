> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

## [lang/typescript] テスト方針

- テストランナーは Vitest を用いる (backend / frontend 共通)。React コンポーネント / API モックの方針は testing.md「GUI (画面) のテスト」に従う
- データ駆動は `it.each` でケース化する

## [lang/typescript] docs コメント

- 関数・メソッド・クラスには TSDoc (`/** ... */`) を書く。引数があれば各 `@param`、戻り値があれば `@returns` を必須とする

## [lang/typescript] 命名

- get アクセサ (get x()) は動詞を付けず対象名にする
- フレームワーク固有の命名慣用 (コンポーネント名・フック名等) はそのフレームワークの規約を優先する

## [lang/typescript] 分岐

- `switch` には必ず `default` 節を書く

## [lang/typescript] 変数宣言

- `var` を使わない (`const` を基本とし、再代入が必要な場合のみ `let` を使う)
