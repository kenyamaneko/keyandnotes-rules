> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

## [lang/kotlin] コルーチン方針

- `GlobalScope` を使わない。呼び出し元から渡された `CoroutineScope`、または `coroutineScope` / `supervisorScope` による構造化された範囲内で起動する
  - なぜ: 構造化されていない起動は例外が呼び出し元に伝搬せず、coding.md「エラーは握りつぶさず根本解決する」に反するため
- `launch` / `async` で発生した例外を catch して握りつぶさない。呼び出し元へ伝搬させるか、`CoroutineExceptionHandler` では伝搬後の後始末 (ログ・リソース解放) のみ行う

## [lang/kotlin] テスト方針

- テストは JUnit5 と AssertJ を用いる
- コルーチンを含むテストは `kotlinx-coroutines-test` の `runTest` を用いる
- 外部境界 (DB・外部API クライアントなど) のモックは MockK を用いる。suspend 関数は `coEvery` / `coVerify` で扱う
- データ駆動は `@ParameterizedTest` + `@CsvSource` / `@MethodSource` でケース化する。ケースが1つだけのときは無理に `@ParameterizedTest` 化せず、通常の `@Test` で書く
- テストの命名は testing.md「テストの命名」を次のとおり割り当てる
  - テスト対象の要素 = テストクラスの `@DisplayName` に日本語で書く (例: `@DisplayName("送料計算") class ShippingFeeTest`)。クラス名は英語でよく、仕様ドキュメントには出さない
  - 各ケースの名前 = `@Test` 関数名にバッククォートで日本語の Given+Then を書く (例: `` fun `注文金額が3000円のとき、送料は無料になる`() ``)
  - 同じ前提のケースが多いときは、`@Nested` の `@DisplayName` に Given を日本語で書いて中間グルーピングにしてよい
  - `@ParameterizedTest` では `name` にテンプレートで Given+Then を書き、プレースホルダ (`{0}` 等) で具体値を展開する
  - `[タグ]` はテストクラスの `@DisplayName` に `[タグ] 本体` の形で書く (Kotlin におけるトップレベルグループ)

## [lang/kotlin] docs コメント

- docs コメントは KDoc (`/** ... */`) 形式で書く。`@param` / `@return` は、型から読み取れない情報 (単位・制約・null や省略時の意味・副作用など) がある引数・戻り値にのみ書く

## [lang/kotlin] 命名

- プロパティ・getter は動詞を付けず対象名 (名詞) にする
- 変更されない定数は `const val` で `UPPER_SNAKE_CASE` にする
- 拡張関数は、拡張する概念が対象の型に本来属する場合にのみ定義する。無関係な業務ロジックを `String` / `Any` など汎用型の拡張関数として生やさない

## [lang/kotlin] 分岐

- 値を返す分岐には `when` 式を使い、sealed class / enum を対象に `else` を書かず全ケースを列挙する。値の追加時の分岐漏れをコンパイルエラーで検知できる
- 副作用を伴う分岐には `when` 文を使う。sealed class / enum など値の分類に対する `when` 文は、網羅していない値を `else` で throw する。空の `else` で無言に通過させない
- 網羅できない値 (外部から受け取った文字列など) は受け取った境界で検証し、想定外なら例外を投げる

## [lang/kotlin] 型と不変性

- ドメインの値は `val` プロパティを持つ `data class` で表し、更新は `copy()` で新しい値を返す
- 非null表明 (`!!`) を使わない。null になり得ないことを型で表すか、`?.` / `?:` / スマートキャストで分岐して扱う
- Java 由来のライブラリ (プラットフォーム型) は、受け取った境界で null を検証してから内側に渡す

## [lang/kotlin] 静的解析と整形

- ktlint で整形を強制し、detekt で静的解析を行う。警告を残さない
