#!/usr/bin/env bash
# install.sh の回帰テスト。HOME を一時ディレクトリに差し替えて動かし、本物の ~/.claude や ~/.gitconfig には触らない。
#   使い方: tests/test-install.sh
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$root/install.sh"
[ -f "$INSTALL" ] || { echo "見つからない: $INSTALL" >&2; exit 2; }
T="$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX")" || exit 2
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
ng(){ echo "  FAIL $1"; fail=$((fail+1)); }
# 本物のグローバル設定に触れないよう、GIT_CONFIG_GLOBAL を明示し XDG_CONFIG_HOME を外す
unset XDG_CONFIG_HOME
export GIT_CONFIG_NOSYSTEM=1
inst(){ HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" bash "$INSTALL" "$@" >"$T/out" 2>&1; }
mkdir -p "$T/home"

echo "1. 新規の導入"
inst; rc=$?
[ $rc -eq 0 ] && ok "正常終了する" || ng "rc=$rc: $(tail -3 "$T/out")"
[ -L "$T/home/.claude/skills/ai-review" ] && [ "$(cd "$T/home/.claude/skills/ai-review" && pwd -P)" = "$(cd "$root/skills/ai-review" && pwd -P)" ] \
  && ok "スキルをリポジトリの skills/ai-review へのシンボリックリンクで入れる" || ng "スキルのリンク"
hp="$(HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" git config --global core.hooksPath)"
[ "$hp" = "$T/home/.git-hooks" ] && ok "core.hooksPath を ~/.git-hooks にする" || ng "core.hooksPath=[$hp]"
[ -x "$T/home/.git-hooks/pre-push" ] && ok "pre-push を実行可能で置く" || ng "pre-push が無い"
grep -q "^skill_dir=\"$T/home/.claude/skills/ai-review\"" "$T/home/.git-hooks/pre-push" 2>/dev/null \
  && ok "pre-push にスキルの場所を埋め込む" || ng "埋め込み: $(grep -n '^skill_dir=' "$T/home/.git-hooks/pre-push" 2>/dev/null)"
bash -n "$T/home/.git-hooks/pre-push" 2>/dev/null && ok "埋め込んだ pre-push は bash の構文として正しい" || ng "pre-push の構文"

echo "2. やり直しても壊れない"
inst; rc=$?
[ $rc -eq 0 ] && ok "同じ内容の再導入は成功する（冪等）" || ng "再導入 rc=$rc: $(tail -2 "$T/out")"

echo "3. 既存の別のフックは上書きしない"
echo '#!/bin/sh
echo other-hook' > "$T/home/.git-hooks/pre-push"
inst; rc=$?
[ $rc -ne 0 ] && grep -q "other-hook" "$T/home/.git-hooks/pre-push" && ok "別の pre-push があれば --force なしでは止まる" || ng "別のフックを上書きした（rc=${rc}）"
inst --force; rc=$?
[ $rc -eq 0 ] && ls "$T/home/.git-hooks/" | grep -q '^pre-push\.bak\.' && grep -q "__AI_REVIEW_SKILL_DIR__\|^skill_dir=" "$T/home/.git-hooks/pre-push" \
  && ok "--force なら元のフックを pre-push.bak.* に退避して入れる" || ng "--force: rc=$rc $(ls "$T/home/.git-hooks/")"

echo "4. 既存の core.hooksPath を尊重する"
rm -rf "$T/home2"; mkdir -p "$T/home2/hooks"
HOME="$T/home2" GIT_CONFIG_GLOBAL="$T/home2/.gitconfig" git config --global core.hooksPath "$T/home2/hooks"
HOME="$T/home2" GIT_CONFIG_GLOBAL="$T/home2/.gitconfig" bash "$INSTALL" >"$T/out2" 2>&1; rc=$?
[ $rc -eq 0 ] && [ -x "$T/home2/hooks/pre-push" ] && ok "設定済みの core.hooksPath の場所に置く" || ng "hooksPath の尊重: rc=$rc $(tail -2 "$T/out2")"

echo "4b. 相対パスの core.hooksPath は止める"
rm -rf "$T/home3"; mkdir -p "$T/home3"
HOME="$T/home3" GIT_CONFIG_GLOBAL="$T/home3/.gitconfig" git config --global core.hooksPath ".githooks"
( cd "$T" && HOME="$T/home3" GIT_CONFIG_GLOBAL="$T/home3/.gitconfig" bash "$INSTALL" >"$T/out3" 2>&1 ); rc=$?
[ $rc -ne 0 ] && [ ! -e "$T/.githooks/pre-push" ] && grep -q '相対' "$T/out3" && ok "相対パスの core.hooksPath なら入れずに止まる" || ng "相対パス: rc=$rc $(tail -1 "$T/out3")"

echo "4c. 印の行が無いフックは、[ai-review] の文字を含んでも別のフックとして扱う"
printf '#!/bin/sh\necho "[ai-review] 自作の組み合わせ"\n./other-check\n' > "$T/home/.git-hooks/pre-push"
inst; rc=$?
[ $rc -ne 0 ] && grep -q "other-check" "$T/home/.git-hooks/pre-push" && ok "自作の組み合わせフックを --force なしで上書きしない" || ng "上書きした rc=$rc"
inst --force >/dev/null

echo "4d. フックの競合で止まるときは、スキルにも触らない"
rm -rf "$T/home4"; mkdir -p "$T/home4/.claude/skills/ai-review" "$T/home4/.git-hooks"; echo old > "$T/home4/.claude/skills/ai-review/SKILL.md"
printf '#!/bin/sh\necho other\n' > "$T/home4/.git-hooks/pre-push"
HOME="$T/home4" GIT_CONFIG_GLOBAL="$T/home4/.gitconfig" bash "$INSTALL" >"$T/out4" 2>&1; rc=$?
[ $rc -ne 0 ] && [ "$(cat "$T/home4/.claude/skills/ai-review/SKILL.md")" = "old" ] && ! ls "$T/home4/.claude/skills" | grep -q bak && ok "競合で止まるときは既存のスキルを置き換えない" || ng "止まる前にスキルを置き換えた rc=$rc"

echo "4e. 退避は skills の外、--copy は冪等"
rm -f "$T/home4/.git-hooks/pre-push"
HOME="$T/home4" GIT_CONFIG_GLOBAL="$T/home4/.gitconfig" bash "$INSTALL" >"$T/out4" 2>&1
! ls "$T/home4/.claude/skills" | grep -q 'ai-review\.' && ls "$T/home4/.claude/" | grep -q 'ai-review-backup' && ok "既存のスキルの退避先は skills の外（二重に読み込まれない）" || ng "退避先: $(ls "$T/home4/.claude/skills" "$T/home4/.claude")"
HOME="$T/home4" GIT_CONFIG_GLOBAL="$T/home4/.gitconfig" bash "$INSTALL" --copy >/dev/null 2>&1
n1="$(ls "$T/home4/.claude/ai-review-backup" | wc -l)"
HOME="$T/home4" GIT_CONFIG_GLOBAL="$T/home4/.gitconfig" bash "$INSTALL" --copy >/dev/null 2>&1
n2="$(ls "$T/home4/.claude/ai-review-backup" | wc -l)"
[ "$n1" = "$n2" ] && [ ! -L "$T/home4/.claude/skills/ai-review" ] && ok "--copy のやり直しは、同じ中身なら退避を増やさない" || ng "--copy の冪等 n1=$n1 n2=$n2"

echo "4f. 埋め込めない文字を含むパスは止める"
mkdir -p "$T/we\"ird"; HOME="$T/we\"ird" GIT_CONFIG_GLOBAL="$T/we\"ird/.gitconfig" bash "$INSTALL" >"$T/out5" 2>&1; rc=$?
[ $rc -ne 0 ] && ok "HOME に \" などを含むとフックに埋め込まずに止まる" || ng "記号入りのパスで続行した"

echo "4g. 実行したリポジトリにリポジトリ単位の core.hooksPath があれば知らせる"
rm -rf "$T/repo5"; git init -q "$T/repo5"; git -C "$T/repo5" config core.hooksPath .git/hooks
( cd "$T/repo5" && HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" bash "$INSTALL" >"$T/out6" 2>&1 )
grep -q 'core.hooksPath' "$T/out6" && grep -q 'ゲートが動きません' "$T/out6" && ok "このリポジトリではゲートが動かないと警告する" || ng "警告なし: $(tail -3 "$T/out6")"

echo "4h. フックに実行権が無ければ、同じ中身でも直す"
chmod -x "$T/home/.git-hooks/pre-push"; inst
[ -x "$T/home/.git-hooks/pre-push" ] && ok "実行権を付け直す" || ng "実行権が無いまま"

echo "5. 前提の確認"
grep -q "python3" "$T/out" && grep -qi "codex" "$T/out" && ok "python3 と Codex CLI の有無を表示する" || ng "前提の表示: $(head -5 "$T/out")"

[ ! -e "$root/skills/ai-review/ai-review" ] && ok "テストの後、リポジトリの中にスキルの複製ができていない" || ng "skills/ai-review/ai-review ができた"
echo "== PASS $pass / FAIL $fail =="
[ $fail -eq 0 ]
