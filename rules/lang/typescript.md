> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

## [lang/typescript] テスト方針

- テストランナーは Vitest を用いる (backend / frontend 共通)
- GUI テストの原則は testing.md「GUI (画面) のテスト」に従い、次のツールで実装する
  - React コンポーネントは Testing Library (`@testing-library/react` + `@testing-library/user-event`) で操作する
  - API 通信のモックは MSW で HTTP 境界 (ネットワーク層) をモックする。api クライアント / モジュールを `vi.mock` 等で直接差し替えない
- データ駆動は `it.each` でケース化する
- テストの命名は testing.md「テストの命名」を次のとおり割り当てる
  - `describe` = テスト対象の要素を日本語で書く (例: `describe("送料計算")`)。必要なら Given / When で `describe` を重ねる
  - `it` = 日本語の自由文で Then まで書く (例: `it("注文金額が3000円のとき、送料は無料になる")`)
  - `it.each` の各ケース名は Given + Then とし、`$値` や `%s` で具体値を埋め込む

## [lang/typescript] docs コメント

- docs コメントは TSDoc (`/** ... */`) 形式で書く。`@param` / `@returns` は、型から読み取れない情報 (単位・制約・null や省略時の意味・副作用など) がある引数・戻り値にのみ書く

## [lang/typescript] 命名

- get アクセサ (get x()) は動詞を付けず対象名にする
- フレームワーク固有の命名慣用 (コンポーネント名・フック名等) はそのフレームワークの規約を優先する

## [lang/typescript] 分岐

- `switch` には必ず `default` 節を書き、想定外の値として throw する。空の `default` で無言に通過させない
  - ユニオン型の分岐では、値を `never` 型の引数で受ける関数 (assertNever) を `default` で呼び、コンパイル時の網羅性チェックと実行時の早期失敗を両立させる

## [lang/typescript] 変数宣言

- `var` を使わない (`const` を基本とし、再代入が必要な場合のみ `let` を使う)
