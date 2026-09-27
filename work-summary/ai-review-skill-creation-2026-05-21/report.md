# /ai-review Skill 作成 + 2 段ゲート運用化

- 日付: 2026-05-21
- 種別: スキル開発 / 実機検証 / 不具合修正 / 運用設計
- 検証先: 検証用の別プロジェクト（Windows）
- スキル本体: `~/.claude/skills/ai-review/SKILL.md`

---

## 1. 作業の目的・背景

ローカル開発で **push する前** に、AI による品質ゲートを確実に通したかった。これまでは Codex / Claude Code (CC) / `/security-review` を都度手で叩いていて、抜け漏れと手間が発生していた。

最終目標は「push 前のローカル AI レビュー運用」の自動化。これを **2 段ゲート** で実現する：

1. **コミット前**: `/ai-review`（本スキル）で未コミット差分の二重レビュー
2. **コミット後 push 前**: `/security-review`（CC 内蔵）でブランチ全体の深掘り

両ゲートを通過するまで push しない、というルールをグローバル指示書にも織り込んだ。

---

## 2. 実施した内容

### 第 1 フェーズ: スキル作成と初回検証

1. **PRD 受領 → Plan 策定**（計画ファイル: `~/.claude/plans/8-claude-code-cc-prd-snappy-orbit.md`、配置先: `$HOME\.claude\skills\ai-review\` 全プロジェクト共通）
2. **SKILL.md 初版作成**
3. **実機検証準備**: `test/ai-review-trial` ブランチで `lib/test-ai-review-sample.ts` に XSS / API キー直書き / コマンドインジェクション / 入力検証なし を仕込む
4. **初回検証 → P1〜P3 を発見**
   - P1: `codex exec` 引数渡しで stdin EOF 待ちハング
   - P1: `--sandbox read-only` で全 shell が `CreateProcessAsUserW failed: 5`
   - P1: 引数経由だとプロンプト 1 行目しか届かない
   - P2: shell 抑止プロンプト不足で codex がローカル探索→空振り
   - P2: `git diff HEAD` のみだと untracked が拾えない
   - P3: タイムアウト未指定、`--output-last-message` 未活用
5. **SKILL.md §3 全面書き換え**で全件解消

### 第 2 フェーズ: 再検証

6. **バックアップ**: `robocopy` で 検証用プロジェクトのバックアップ（5.3 MB）
7. **再検証**: 別セッションで `/ai-review` 実行 → Codex 25.38 秒で正常完了、High 2 / Medium 3 / Low 1 検出、両形式レポート生成、HEAD 不変

### 第 3 フェーズ: テスト痕跡の片付け

8. テスト用ファイル・引継書・テスト出力・テストブランチを削除
9. `.gitignore` に `.claude/settings.local.json` / `.review-reports/` を追記

### 第 4 フェーズ: HTML 出力の改善 (P4 - UX)

10. **HTML が `<pre>` ラッパだけで読みづらい**問題を発見
11. **§7 を全面書き換え**: CC が md と html を別々にセマンティック構築する方針へ
    - 7.1 設計理由 / 7.2 テンプレ方針 / 7.3 9 構成要素 / 7.4 配色 / 7.5 実装手順 / 7.6 PowerShell サンプル / 7.7 HTML 骨格テンプレ

### 第 5 フェーズ: 2 段ゲート運用の設計 (P5)

12. 「`/security-review` を毎回呼ぶか」議論 → 自動連鎖は不可（スコープがズレている）と判断
13. **SKILL.md §8 を全面書き換え**
    - 8.1 スコープ違いの明示 / 8.2 ワークフロー図 / 8.3 結論 3 パターン / 8.4 `origin/HEAD` 対処
14. **§6 出力テンプレ更新**: 末尾を「次のステップ」へ。2 段ゲート第 1 段である旨を明示
15. **`~/.claude/CLAUDE.md` に「Push 前ローカル AI レビュー（2 段ゲート運用）」を追記**

### 第 6 フェーズ: レポート整理

16. `/work-summary` 初回出力を 検証用プロジェクト配下から、この記録用のディレクトリの `work-summary/` へ移動
17. HP 側 `.gitignore` の `work-summary/` 行は保険として残置

---

## 3. 変更したファイル一覧

### 新規作成（永続）

| 種別 | パス | 備考 |
|---|---|---|
| 新規 | `~/.claude/skills/ai-review/SKILL.md` | スキル本体。本番運用可 |
| 新規 | `~/.claude/plans/8-claude-code-cc-prd-snappy-orbit.md` | 計画ファイル |
| 更新 | `~/.claude/CLAUDE.md` | 2 段ゲート運用セクション追記 |

### バックアップ（1 週間後削除予定）

| 種別 | パス | サイズ |
|---|---|---|
| 一時 | 検証用プロジェクトのバックアップ | 5.3 MB |

### 検証用に作成 → 削除済み

| 種別 | パス |
|---|---|
| 削除 | `lib/test-ai-review-sample.ts`（HP プロジェクト内） |
| 削除 | `AI-REVIEW-TEST-HANDOFF.md` |
| 削除 | `.review-reports/`（HP プロジェクト内） |
| 削除 | ブランチ `test/ai-review-trial` |

### HP プロジェクト側の残更新

| 種別 | パス | 内容 |
|---|---|---|
| 更新 | `.gitignore` | `.claude/settings.local.json` / `.review-reports/` / `work-summary/` を追記 |

---

## 4. 結果・残課題・次のアクション

### 完了

- `/ai-review` スキル本番運用可能
- 実機検証 2 ラウンドで Codex 25.38s 正常完了、仕込んだ脆弱性 4 件すべて検出
- Windows 環境固有のハマりどころ 6 点を SKILL.md §3 で完全解消
- HTML 出力をダッシュボード風に刷新（P4）
- 2 段ゲート運用を SKILL.md §8 と CLAUDE.md で正式化（P5）

### 残課題

- 検証用プロジェクトのバックアップの手動削除（1 週間後目安）
- HP プロジェクト側 `.gitignore` 追記分のコミット（他の untracked とまとめて）
- 新しい HTML 出力（§7 改修後）の実機確認は未実施
- 2 段ゲート全体の通し試運転は未実施（CLAUDE.md は新セッションから有効）

### 次のアクション

- 新セッション起動して 2 段ゲート全体を 1 度通す（任意）
- 別プロジェクトで `/ai-review` を試運転して汎用性確認
- 利用が安定したら SKILL.md §10 検証履歴のアーカイブ整理

---

## 5. 作業内容のまとめ

「push 前のローカル AI レビュー」を実現する全プロジェクト共通 Claude Code Skill `/ai-review` を新規作成し、Next.js HP プロジェクトで実機検証を 2 ラウンド実施。Windows 環境固有のハマりどころ 6 点（P1〜P3）を SKILL.md §3 全面書き換えで解消し、HTML 出力の視認性問題（P4）と運用設計（P5）も追加対応した。最終的に「`/ai-review`（未コミット差分） → コミット → `/security-review`（ブランチ全体） → push」という **2 段ゲート運用** を `~/.claude/CLAUDE.md` に明文化し、全プロジェクト共通の標準として定着させた。本番運用可能な状態で完了。
