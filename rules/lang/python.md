> NOTE: このファイルは原則として人間が運用する。例外的に許可があった場合のみClaude Codeが修正しても良い。

## [lang/python] docs コメント

- 関数・メソッド・クラスには Google スタイルの docstring を書く。引数があれば `Args:` セクション、戻り値があれば `Returns:` セクションを必須とする

## [lang/python] テスト方針

- テストは pytest を用いる
- データ駆動は `@pytest.mark.parametrize` でケース化する
- テストの命名は testing.md「テストの命名」を次のとおり割り当てる
  - テストクラス (またはモジュール) = テスト全体の名前
  - テスト関数名 = 各ケースの名前。`test_` に続けて日本語で書く
  - `parametrize` では 1 つの関数が複数のケースを持つため、割り当てを一段ずらす。テスト関数名 = テスト全体の名前とし、各ケースの名前は `pytest.param` の `id` に日本語で書く
- 日本語の id は既定で `\uXXXX` 形式にエスケープされて読めなくなるため、pytest の設定で `disable_test_id_escaping_and_forfeit_all_rights_to_community_support = True` を設定する

## [lang/python] 命名

- @property は動詞を付けず対象名 (名詞) にする
