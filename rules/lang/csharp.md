> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

## [lang/csharp] 設計思想

- 例外は自動伝搬させる (system-design.md「エラーの伝搬」の C# での具体化)
- ASP.NET 系では原則として `app.UseExceptionHandler` を唯一の catch 地点とする。system-design.md「エラーの伝搬」が許す目的の catch は許容する

## [lang/csharp] コーディング方針

- `FirstOrDefault` + silent default を禁止する。契約上存在するなら `First()` または `MustGet` 系を使う
- 値の分類 (enum・種別・状態) に対する分岐では、網羅していない値を `switch` の `default` / 最後の `else` で `throw` する。代用の値 (空文字・0・`"?"`) を返さない
- 値を返す分岐には switch 式を使い、default アームは `throw`。副作用を伴う分岐には switch 文を使う
- フィルタ・変換・集計には LINQ を使う。副作用を伴うループには `foreach` 文を使い、`List<T>.ForEach()` は使わない

## [lang/csharp] パーサ方針

- YAML / JSON 等の構造化データパーサで unknown 値を silent drop しない。typo 検知のため全パーサで unknown → throw を徹底する

## [lang/csharp] ディレクトリ構成

- 実装はソリューションに置き、実装プロジェクトは `<ソリューション名>.<役割>` の名前で作る
- アーキテクチャ上の役割の名前は system-design.md「クリーンアーキテクチャと役割の名前」に従い、PascalCase で書く (例: `Domain`、`UseCase`)
- テストは、実装プロジェクトとは別のテスト専用プロジェクトに置く。実装プロジェクトごとに `<実装プロジェクト名>.Tests` を作り、複数のテストプロジェクトで共有する部品は `Tests.Shared` に置く

## [lang/csharp] テスト方針

- テストは xUnit と FluentAssertions を用いる
- ケースの項目は `Trait` で載せる。`Trait` は属性なので値が実行前に決まり、`[Theory]` の行ごとには変えられない
  - Given・When・Then が行ごとに変わるケースは、`[Theory]` にせず、行ごとに `[Fact]` を書く
  - testing.md「ケースの書き方」のテーブル駆動への統合は、C# では行わない
- テストの命名は testing.md「テストの命名」を次のとおり割り当てる
  - `[区分:大機能(:中機能)]小機能` = クラスの `[Trait("区分・大機能・中機能・小機能", "...")]` (例: `[Trait("区分・大機能・中機能・小機能", "[本体:注文]送料計算")]`)。クラス名は英語でよく、テストケースカタログには出さない
  - ケース = `[Fact(DisplayName = "...")]`
  - ケースの項目 = 各テストメソッドの `[Trait("Given", "...")]`・`[Trait("When", "...")]`・`[Trait("Then", "...")]`・`[Trait("種別", "...")]`・`[Trait("正常異常", "...")]`・`[Trait("観点", "...")]`。`観点` は省略可で、観点ごとに `[Trait("観点", "境界値")]` を 1 つずつ付ける。JunitXml.TestLogger 8.1.0 で JUnit XML の `<property>` に出す
    - ステップが複数のケースは、キー名に何番目のステップかを付ける (`Given1`・`When1`・`Then1`、`Given2`・`When2`・`Then2`)。同じキー名を繰り返すと、出力がキーごとにまとまり、ステップの対応が失われるため
    - 1 つのステップの `When` が複数の操作のときは、同じキー名 (`When1`) を繰り返す。同じキー名の値は、書いた順に出る

## [lang/csharp] docs コメント

- docs コメントは XML doc コメント形式で書き、`<summary>` を書く。`<param>` / `<returns>` は、型から読み取れない情報 (単位・制約・null や省略時の意味・副作用など) がある引数・戻り値にのみ書く

## [lang/csharp] 命名

- 非同期メソッドは Async サフィックスを付ける
- プロパティは名詞にする
  - getter に動詞を付けない
- インターフェースは I で始める
