> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

## [lang/python] docs コメント

- 関数・メソッド・クラスには Google スタイルの docstring を書く。引数があれば `Args:` セクション、戻り値があれば `Returns:` セクションを必須とする

## [lang/python] テスト方針

- テストは pytest を用いる
- データ駆動は `@pytest.mark.parametrize` でケース化する

## [lang/python] 命名

- @property は動詞を付けず対象名 (名詞) にする
