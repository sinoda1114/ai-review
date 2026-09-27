# /ai-review v3 への刷新（ベンチマークで磨いた push 前ゲート）

- 日付: 2026-09-23〜24
- 作業ディレクトリ: `~/.claude`（スキル本体）、ベンチマーク用のリポジトリ（測定、非公開）
- 種別: 実装・検証

v2 までの「ECC 版 `/code-review` ＋ Codex ＋ 公式 `/security-review`」を、ベンチマークで確かめた自前の観点（own-review・own-security）に置き換え、結論を BLOCK / MUST-ADDRESS / PASS の 3 段にした。完成したゲートを v3 自身の変更にかけて 10 周し、60 件以上の穴を直してから配布した。

## 1. 作業の目的・背景

- 目的: ベンチマークの結果をもとに `/ai-review`（push 前のローカルの第 1 ゲート）を磨く。品質を上げ、脆弱性をローカルで潰し、PR のレビュー Bot（第 2 ゲート）の負担を減らす。品質と検証を重視し、AI の確認の手間が増えることは許容する。
- きっかけ:
  - GPT-6 Sol / Luna / Astra、Opus 5.5 が出た。
  - `~/.claude/commands/code-review.md`（ECC）が組み込みの `/code-review` を上書きしていて、v2 のゲートも過去のベンチ値も ECC 版で動いていたと判明した（2026-09-23）。
- 制約:
  - 公開版は Claude Code と Codex CLI だけで動く（ECC と JEV は外す）。
  - 自前の観点に OWASP Benchmark 固有の癖を書かない。
  - 確認用データは測るだけで、中身を見て直さない（過学習の防止）。

## 2. 実施した内容

1. 新モデルを公式の機能のまま素の環境で測った（ベンチマーク側に記録）。
   - Codex 純正 review: GPT-6 Sol 0.964、Luna 0.818、Astra 0.945、GPT-5.6 Sol 0.982。
   - 素の `/code-review`: Opus 5.5 0.855、Opus 5 0.491。
2. 分析用データ（case-110-balanced）で誤判定の原因を分類し、自前の観点を v1 から v5 まで作った。
   - v1: 誤検知が多い（0.745）。
   - v2: 確認用で 0.982。
   - v3: 止めすぎ（バグのない 18 件中 15 件を BLOCK）。
   - v4: 結論を 3 段にし、深刻度の基準を明文化した。
   - v5: 3 文を修正して完成。
3. 確認用データで方式を決めた（`docs/ai-review-deep-plan.md` の①②③）。
   - ① Claude 側は自前観点 v5 × Opus 5.5。
     - 2 つ目の確認用 OWASP で 1.000。
     - バグ 46 件はすべて検出。
     - バグのない 21 件で止めすぎは 0。
   - ② Codex 側は純正の `codex exec review` × GPT-6 Sol。自前の観点を渡すと悪化した（0.964 から 0.800）。
   - ③ 昇格の深掘りは、自前のセキュリティ専用観点 own-security × Opus 5.5。確認用 OWASP で 1.000（公式 `/security-review` は 0.727）。
4. v3 を実装した。
   - `prompts/own-review.md`・`own-security.md`、`scripts/gate.py`（下限・判定表の検査・記録・項目の処理）、`resolve-item.sh`。
   - MUST-ADDRESS は 1 件ずつ片づける。「直す」か、「理由を記録し、別のサブエージェントが検証する」かのどちらか。高リスクはユーザーの承認が要る（C 案）。
   - `--deep`（5 本）を足した。JEV を削除した。
5. v3 のゲートを v3 自身の変更（約 2,500 行）にかけて 10 周した。直した主な穴は次のとおり。
   - レビュー対象のファイルが開発者の権限で動く経路を 4 種類塞いだ（どれも実測で確認）。
     - `Bash(git:*)` の許可で `git -c core.fsmonitor=…` の任意実行ができた。
     - ユーザーの allow ルールとレビュー対象の `.claude/settings.json` のフックが混入した。
     - pre-push フックがリポジトリ直下の `json.py` を読み込んだ。
     - 変数の上書きで、起動ディレクトリの同名スクリプトを実行した。
   - 対処: レビュアーを `--setting-sources "" --safe-mode --strict-mcp-config` で起動し、道具を読み取り系の git に絞り、フックの python を `-I` で起動した。
   - 記録の抜け道を塞いだ。
     - `--base HEAD` で比較範囲を狭める。
     - `gate.py` の直接呼び出しで人の承認を書く。
     - ダミー実行で push が通る。
   - 結論の読み取りの揺れには、最後の行の `VERDICT: X` を読む形にして対処した。
   - 人の承認は、端末（/dev/tty）で ID を打ち込む形にした。
6. 配布した。
   - 個人の設定リポジトリへ push した。
   - クラウド用の配布リポジトリへ同期した。
   - 個人のプロジェクトに PR を出して配布した。
   - あわせて、CLAUDE.md と Codex 用 AGENTS.md の v2 の記述を v3 に合わせた。

## 3. 変更したファイル一覧

| 種別 | パス | 備考 |
|---|---|---|
| 新規 | `~/.claude/skills/ai-review/DESIGN-v3.md` | 設計の正本 |
| 新規 | `~/.claude/skills/ai-review/prompts/own-review.md`・`own-security.md` | 自前の観点（v5・v1） |
| 新規 | `~/.claude/skills/ai-review/scripts/gate.py`・`resolve-item.sh`・`probe-permissions.sh` | 下限・記録・項目の処理、実機の権限確認 |
| 更新 | `~/.claude/skills/ai-review/SKILL.md`・`run-reviews.sh`・`record-gate.sh`・`hooks/pre-push`・`test-gate.sh`・`test-isolation.sh` | v3 化と 10 周の修正 |
| 削除 | `~/.claude/skills/ai-review/scripts/jev-judge.py`・`jev-escalation.py` | JEV を外した |
| 更新 | `~/.claude/CLAUDE.md`・`env/codex/AGENTS.md`・`~/.codex/AGENTS.md` | ゲートの記述を v3 に |
| 更新 | `~/.git-hooks/pre-push` | v3 のフック（v2 の控えは `pre-push.v2-backup-20260923`） |
| 更新 | `docs/ai-review-deep-plan.md` ほか | 計画・結論・実運用の記録 |

## 4. 結果・残課題・次のアクション

### 完了

- v3 を個人の設定・配布用リポジトリ・個人のプロジェクト（PR）へ配布した。
- 回帰テストは `test-gate.sh` 169/169、`test-isolation.sh` 41/41、`probe-permissions.sh` 14/14（実機）。
- 10 周の実運用の記録（レビュアー別の発見数）を残した。
  - own-review は 70 件中 43 件（単独 21 件）で、主軸。
  - own-security は単独 9 件で、上乗せする価値がある。`json.py` の任意実行を見つけたのは、own-security だけ。
  - `--deep` の追加 2 本は単独 8 件。今の推奨条件で使うのが妥当。
- 所要時間: 通常 2 本で 3.5〜7 分、深掘りを足すと 7〜15 分、`--deep` で 7.5〜15 分。

### 残課題

- 後回しにした Medium 以下の指摘: 個人の Issue で管理。
  - `.review-reports` のシンボリックリンク経由の書き込み。
  - Codex が `AGENTS.md` を読む。
  - 人の承認の記録は、AI が書ける場所にある、など。
- 「後回し（Issue 化）」の片づけ方がゲートに無い。
- コストは未計測（`claude -p` の text 出力に使用量が出ない）。
- own-security の「要確認」は、8 件中 4 件が実測で成り立たなかった。

### 次のアクション

- 配布先の PR のマージ（Codex のレビュー指摘で、手順書の v2 の記述を直してからマージ）。
- 「後回し」の片づけ方を足す。
- 一般のアプリの変更で、同じ傾向（own-security と `--deep` の上乗せ）になるかを実運用で記録する。

## 5. 作業内容のまとめ

ベンチマークで「どの観点・どのモデルが実際に効くか」を確認用データで確かめてから、`/ai-review` を v3 に刷新した。v3 は Claude 側を自前観点 v5（Opus 5.5）、Codex 側を純正 review（GPT-6 Sol）、昇格を own-security にして、結論を 3 段にした。

完成したゲートを自分自身にかけると、レビュアーの起動方法そのものに、開発者の権限でコードが動く穴が複数見つかった。どれも実測で確かめて塞いだ。

直すたびに新しい指摘が出て周回が止まらなかったので、「BLOCK・High だけ直し、Medium 以下は Issue」という止める条件を決めて配布した。
