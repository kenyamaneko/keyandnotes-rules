> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

## [lang/python] docs コメント

- 関数・メソッド・クラスには Google スタイルの docstring を書く。引数があれば `Args:` セクション、戻り値があれば `Returns:` セクションを必須とする

## [lang/python] テスト方針

- テストは pytest を用いる
- データ駆動は `@pytest.mark.parametrize` でケース化する
- テストの命名は testing.md「テストの命名」を次のとおり割り当てる
  - テスト対象の要素 = テストクラス名に日本語で書く。`Test` に続けて日本語 (例: `class Test送料計算:`)。pytest は `Test` で始まるクラスを集める
  - 各ケースの名前 = テスト関数名。`test_` に続けて日本語で書く
  - `parametrize` では 1 つの関数が複数のケースを持つため、割り当てを一段ずらす。関数名にはテーブル全体で共有される操作 (When) を `test_` + 日本語で書き、各ケースの名前 (Given + Then) は `pytest.param` の `id` に日本語で書く
- 日本語の id は既定で `\uXXXX` 形式にエスケープされて読めなくなるため、pytest の設定で `disable_test_id_escaping_and_forfeit_all_rights_to_community_support = True` を設定する

## [lang/python] 命名

- @property は動詞を付けず対象名 (名詞) にする
