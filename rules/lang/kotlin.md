> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

## [lang/kotlin] ディレクトリ構成

- 実装はアプリのパッケージに置く
- 役割の名前は system-design.md「クリーンアーキテクチャと役割の名前」に従う。Kotlin 固有の役割は次のとおり。使わないものは作らなくてよい
  - `ui`: 画面
- テストは Gradle の標準のソースセットに置く。Android の実機やエミュレータを使わないテストは `test` に、実装と同じパッケージ構成で置き、Android の実機やエミュレータで動かすテストは `androidTest` に置く

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
  - `[区分:大機能(:中機能)]小機能` = 最も外側のテストクラスの `@DisplayName` (例: `@DisplayName("[本体:注文]送料計算") class ShippingFeeTest`)。クラス名は英語でよく、テスト観点カタログには出さない
  - ケース = `@Test` 関数名 (バッククォートで囲める。例: `` fun `注文金額が3000円のとき、注文画面の送料の計算で、送料を計算すると、送料は無料になる`() ``)
    - JVM の関数名に使えない記号 (`.` `;` `[` `]` `/` `<` `>` `:` `\`) を含むケースは、関数名を英語にして `@DisplayName` にテスト名を書く
  - ケースの項目 = テスト関数の引数に受け取る `TestReporter` の `publishEntry("Given", "...")`。キーは `Given`・`When`・`Then`・`種別`・`正常異常`。ステップは、`Given` (省略可)、`When` (手順の数だけ)、`Then` の順に繰り返して呼ぶ。項目は JUnit XML の `<property>` に出る。Gradle 9.4.0 以降を用いる
  - `@ParameterizedTest` のケース = `name` のテンプレート (プレースホルダ `{0}` 等で値を展開する)。関数名は英語でよい

## [lang/kotlin] docs コメント

- docs コメントは KDoc (`/** ... */`) 形式で書く。`@param` / `@return` は、型から読み取れない情報 (単位・制約・null や省略時の意味・副作用など) がある引数・戻り値にのみ書く

## [lang/kotlin] 命名

- プロパティ・getter は動詞を付けず対象名 (名詞) にする
- 変更されない定数は `const val` で `UPPER_SNAKE_CASE` にする
- 拡張関数は、拡張する概念が対象の型に本来属する場合にのみ定義する。無関係な業務ロジックを `String` / `Any` など汎用型の拡張関数として生やさない

## [lang/kotlin] 分岐

- 値を返す分岐には `when` 式を使い、sealed class / enum を対象に `else` を書かず全ケースを列挙する。値の追加時の分岐漏れをコンパイルエラーで検知できる
- 副作用を伴う分岐には `when` 文を使う。sealed class / enum など値の分類に対する `when` 文は、網羅していない値を `else` で throw する。空の `else` で無言に通過させない
- 列挙型や `sealed class` で表せない値 (例: 外部から受け取った配送業者コードの文字列) が想定外なら、`adapter` と `presentation` で例外を投げる

## [lang/kotlin] 型と不変性

- ドメインの値は `val` プロパティを持つ `data class` で表し、更新は `copy()` で新しい値を返す (system-design.md「不変性」の Kotlin での具体化)
- 非null表明 (`!!`) を使わない。null になり得ないことを型で表すか、`?.` / `?:` / スマートキャストで分岐して扱う
- Java 由来のライブラリから受け取った値 (プラットフォーム型) は、そのライブラリを呼び出したコードで null を検証してから、ほかのコードに渡す

## [lang/kotlin] 静的解析と整形

- ktlint で整形を強制し、detekt で静的解析を行う。警告を残さない
