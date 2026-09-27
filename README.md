# ai-review — push 前に通す AI のレビューゲート

Claude Code のスキルです。`git push` の前に、2 つの AI（Claude と Codex）に独立して差分をレビューさせ、**脆弱性とバグを見つけたら push を止めます**。

- Claude 側は、ベンチマークで作り込んだ自前のレビュー観点（プロンプト）を使います。Codex 側は、Codex CLI の純正 review 機能をそのまま使います。
- 結論は `BLOCK`（直すまで止める）/ `MUST-ADDRESS`（1 件ずつ片づけるまで止める）/ `PASS` の 3 段です。
- 認証・決済・スキーマなど高リスクの差分では、セキュリティ専用の観点による深掘りが自動で加わります。
- git の pre-push フックが記録を確かめ、レビューを通していない push を止めます。ただし、`AI_REVIEW_BYPASS=1` や `git push --no-verify`、リポジトリ単位の `core.hooksPath` で迂回できます（`/ai-review` は後者を見つけると警告します）。

仕組みの全体像（図つき）は [`ai-review-v3-before-after.html`](ai-review-v3-before-after.html) にあります（ダウンロードしてブラウザで開いてください）。

## 仕組み（要約）

```
commit（何回でも）
  │  /ai-review
  ▼
HEAD の clean な worktree を作る ─ 未コミットの変更や作業中の書き換えを混ぜない
  │
  ├─ 昇格の判定（パス・危険な API の追加行・規模・秘密情報）
  │
  ├─ 並列・独立に ┬ own-review   … 自前の観点を claude -p に直接渡す（Claude Opus）
  │               └ codex review  … Codex 純正 review をそのまま（GPT-6 Sol）
  │               （高リスクなら own-security、--deep なら Fable・Astra も加えて 5 本）
  ▼
結論の下限（生の出力から機械的に決まる）と、指摘の和集合で結論を出す
  │  MUST-ADDRESS は 1 件ずつ「直す」か「理由を記録し、別のサブエージェントが検証」
  ▼
git push ─ pre-push フックが記録（.review-reports/latest.json）を確かめる
```

- レビュアーは、ユーザーやレビュー対象の設定（CLAUDE.md、フック、`.claude/`・`.codex/`、`AGENTS.md`）を読まない形で起動し、道具は読み取りと読み取り系の git だけに絞ります。レビュー対象のコードにレビュアーを乗っ取られないようにするためです。
- 効いているかは `skills/ai-review/scripts/probe-permissions.sh` で実機で確かめられます。

## 必要なもの

| もの | 用途 |
|---|---|
| Claude Code CLI（`claude`） | 自前観点のレビュアー。Opus 5.5 を使う |
| Codex CLI（`codex`） | 二重レビューのもう一方。無いと Claude 側だけになり、毎回「未取得」の項目として記録に残る |
| python3（3.8 以上、標準ライブラリのみ） | 結論の判定と記録 |
| git、bash | ― |

macOS と Linux で動かしています。Windows は WSL で使ってください。

## 導入

### スクリプトで入れる（おすすめ）

```bash
git clone https://github.com/sinoda1114/ai-review.git
cd ai-review
./install.sh
```

clone する場所は `~/.claude/skills/` の外にしてください（`~/.claude/skills/ai-review` に直接 clone して `install.sh` を実行すると、リポジトリ自身を退避してしまいます）。

`install.sh` は次の 3 つを行います。中身を読んでから実行してください。

1. 前提のコマンドを確かめる
2. スキルを `~/.claude/skills/ai-review` として入れる（このリポジトリへのシンボリックリンク。`--copy` でコピー）
3. pre-push フックをグローバルの `core.hooksPath`（無ければ `~/.git-hooks`）に置く。別の pre-push フックがあれば止まる（`--force` で退避して入れる）

### プラグインとして入れる

```
/plugin marketplace add sinoda1114/ai-review
/plugin install ai-review@ai-review
```

プラグインで入るのはスキルだけです。**pre-push フックは入らない**ので、止める仕組みが要るなら `install.sh` も実行するか、`skills/ai-review/hooks/pre-push` を自分で置いてください。

## 使い方

```
/ai-review            # origin/HEAD から HEAD までのコミット済み差分をレビューする（push 前のゲート）
/ai-review --local    # 未コミットの変更をレビューする（途中の確認。ゲートにはならない）
/ai-review --deep     # 強化版。レビュアーを 5 本にする
```

- 各リポジトリで初回だけ `git remote set-head origin -a` が必要です。
- 高リスクの項目を「直さない」と決めたときは、ユーザー自身が端末で `resolve-item.sh --id <ID> --approve-human` を実行して承認します（AI は代行しません）。
- どうしてもレビューせずに push するときだけ `AI_REVIEW_BYPASS=1 git push`。

## 測った結果

この形は、OWASP Benchmark から抽出した脆弱性のデータと、実際の fix コミットから作ったバグのデータで、方式を比べて決めました。設計に使っていない確認用のデータでの結果です。

| 項目 | 結果 |
|---|---|
| 脆弱性（OWASP Benchmark 110 件、確認用） | 自前観点 × Opus 5.5 で Score 1.000（見逃し 0・誤検知 0）。参考: Claude Code 公式 `/code-review` × Opus 5.5 は 0.855 |
| バグのある変更 46 件 | すべて検出（BLOCK 28・MUST-ADDRESS 18） |
| バグのない変更 21 件 | 止めすぎ 0（BLOCK した 4 件はどれも本物のバグだった） |
| 所要時間 | 通常 3.5〜7 分、深掘り込み 7〜15 分、`--deep` 7.5〜15 分 |

経緯と数字の詳細は [`docs/ai-review-deep-plan.md`](docs/ai-review-deep-plan.md) にあります。

## 限界

- **人の承認は技術的には強制できません**。承認の記録（`.review-reports/latest.json`）は、作業中の AI も書けるファイルです。端末での ID の入力で誤って書く経路は塞いでいますが、迂回はできます。手順と記録で担保する前提です。
- **クラウド（claude.ai/code）では動きません**（Codex CLI が無いため）。
- **コストは測っていません**。
- 本物だが急がない指摘を「後回し」にする片づけ方がまだ無く、直すか理由を検証させるかの 2 択です。
- 結論の判定は AI の出力の書式（`VERDICT:` 行や Codex の `[P1]` など）に頼っています。書式が変われば、止める側に倒すように作ってあります。

## このリポジトリの中身

| パス | 中身 |
|---|---|
| `skills/ai-review/` | スキル本体（`SKILL.md`・`DESIGN-v3.md`・プロンプト・スクリプト・フック） |
| `install.sh`、`.claude-plugin/` | 導入スクリプト、プラグインの定義 |
| `tests/` | 導入スクリプトのテスト（スキルのテストは `skills/ai-review/scripts/test-*.sh`） |
| `ai-review-v3-before-after.html` | v2 から v3 で変わったところ（図つき） |
| `docs/` | 設計と判断の記録（計画、ゲートの設計、部品の検証） |
| `work-summary/`、`history/` | 作業の記録と過去の版 |

## ライセンス

MIT
