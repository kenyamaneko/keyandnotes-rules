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
- テストのグルーピングは xUnit のネストクラスで構造化する
- 入力と期待値だけが異なる同一の振る舞いは `[Theory]` + `[InlineData]` でケースを表化する
  - テストの準備が複雑で同じ構造にできない場合は `[Fact]` のまま個別に残す
- テストの命名は testing.md「テストの命名」を次のとおり割り当てる
  - `[区分:大機能(:中機能)]小機能` = クラスの `[Trait("区分・大機能・中機能・小機能", "...")]` (例: `[Trait("区分・大機能・中機能・小機能", "[本体:注文]送料計算")]`)。クラス名は英語でよく、テスト観点カタログには出さない
  - 共通の前提 = ネストクラスの `[Trait("共通の前提", "...")]`
  - 共通の操作 = ネストクラスの `[Trait("共通の操作", "...")]`
  - 種別 = ネストクラスの `[Trait("種別", "...")]`
  - 正常異常 = ネストクラスの `[Trait("正常異常", "...")]`
  - ケースの名前 = `[Fact(DisplayName = "...")]` / `[Theory(DisplayName = "...")]`
  - `[Theory]` の各ケースは引数値がテスト名に展開される。値だけで Given + Then が読み取れない場合は、ケースの名前の文字列を先頭引数に加える

## [lang/csharp] docs コメント

- docs コメントは XML doc コメント形式で書き、`<summary>` を書く。`<param>` / `<returns>` は、型から読み取れない情報 (単位・制約・null や省略時の意味・副作用など) がある引数・戻り値にのみ書く

## [lang/csharp] 命名

- 非同期メソッドは Async サフィックスを付ける
- プロパティは名詞にする
  - getter に動詞を付けない
- インターフェースは I で始める
