#!/usr/bin/env bash
# install.sh の回帰テスト。HOME を一時ディレクトリに差し替えて動かし、本物の ~/.claude や ~/.gitconfig には触らない。
#   使い方: tests/test-install.sh
set -u
root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
INSTALL="$root/install.sh"
[ -f "$INSTALL" ] || { echo "見つからない: $INSTALL" >&2; exit 2; }
T="$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX")" || exit 2
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
ng(){ echo "  FAIL $1"; fail=$((fail+1)); }
# 本物のグローバル設定に触れないよう、GIT_CONFIG_GLOBAL を明示し XDG_CONFIG_HOME を外す
unset XDG_CONFIG_HOME
# git のフックの中などから呼ばれても、外側のリポジトリや設定に作用しないようにする
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
export GIT_CONFIG_NOSYSTEM=1
# CLI の無い環境（CI など）でも動くよう、偽の claude・codex を PATH の先頭に置く
mkdir -p "$T/bin"
for c in claude codex; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; chmod +x "$T/bin/$c"; done
export PATH="$T/bin:$PATH"
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
[ $rc -eq 0 ] && ls "$T/home/.git-hooks/" | grep -q '^pre-push\.bak\.' && grep -q "^skill_dir=\"$T/home/.claude/skills/ai-review\"" "$T/home/.git-hooks/pre-push" \
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
rm -rf "$T/repo5"; GIT_CONFIG_GLOBAL=/dev/null git init -q "$T/repo5"; git -C "$T/repo5" config core.hooksPath .git/hooks
( cd "$T/repo5" && HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" bash "$INSTALL" >"$T/out6" 2>&1 )
grep -q 'core.hooksPath' "$T/out6" && grep -q 'ゲートが動きません' "$T/out6" && ok "このリポジトリではゲートが動かないと警告する" || ng "警告なし: $(tail -3 "$T/out6")"

echo "4h. フックに実行権が無ければ、同じ中身でも直す"
chmod -x "$T/home/.git-hooks/pre-push"; inst
[ -x "$T/home/.git-hooks/pre-push" ] && ok "実行権を付け直す" || ng "実行権が無いまま"

echo "4i. リポジトリが導入先（~/.claude/skills/ai-review）の中にあれば止める"
rm -rf "$T/home6"; inner="$T/home6/.claude/skills/ai-review"; mkdir -p "$inner"
cp "$INSTALL" "$inner/"; cp -R "$root/skills" "$inner/"
HOME="$T/home6" GIT_CONFIG_GLOBAL="$T/home6/.gitconfig" bash "$inner/install.sh" >"$T/out7" 2>&1; rc=$?
[ $rc -ne 0 ] && [ -f "$inner/install.sh" ] && [ ! -e "$T/home6/.claude/ai-review-backup" ] && [ ! -e "$T/home6/.gitconfig" ] \
  && ok "導入先の中に clone したリポジトリは退避せずに止まる" || ng "リポジトリ自身を退避した rc=$rc $(tail -2 "$T/out7")"

echo "4j. include で設定した core.hooksPath も尊重する"
rm -rf "$T/home7"; mkdir -p "$T/home7/inc-hooks"
printf '[core]\n\thooksPath = %s\n' "$T/home7/inc-hooks" > "$T/home7/inc.gitconfig"
printf '[include]\n\tpath = %s\n' "$T/home7/inc.gitconfig" > "$T/home7/.gitconfig"
HOME="$T/home7" GIT_CONFIG_GLOBAL="$T/home7/.gitconfig" bash "$INSTALL" >"$T/out8" 2>&1; rc=$?
[ $rc -eq 0 ] && [ -x "$T/home7/inc-hooks/pre-push" ] && [ -z "$(git config --file "$T/home7/.gitconfig" --get core.hooksPath)" ] \
  && ok "include 先の core.hooksPath に置き、~/.gitconfig に別の値を書き足さない" || ng "include: rc=$rc $(tail -2 "$T/out8")"

echo "4k. 環境変数などで core.hooksPath が上書きされていれば、書き換える前に止まる"
rm -rf "$T/home8"; mkdir -p "$T/home8"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$T/elsewhere" \
  HOME="$T/home8" GIT_CONFIG_GLOBAL="$T/home8/.gitconfig" bash "$INSTALL" >"$T/out9" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q "$T/elsewhere" "$T/out9" && [ ! -e "$T/home8/.gitconfig" ] && [ ! -e "$T/home8/.claude" ] && [ ! -e "$T/home8/.git-hooks" ] \
  && ok "環境変数などで上書きされてゲートが効かないなら、何も書き換えずに止まる" || ng "実効値の確認 rc=$rc $(ls -a "$T/home8") $(tail -2 "$T/out9")"

echo "4l. フックの置き場所を他人が書き換えられるなら止める"
rm -rf "$T/home9"; mkdir -p "$T/home9/hooks"; chmod 777 "$T/home9/hooks"
HOME="$T/home9" GIT_CONFIG_GLOBAL="$T/home9/.gitconfig" git config --global core.hooksPath "$T/home9/hooks"
HOME="$T/home9" GIT_CONFIG_GLOBAL="$T/home9/.gitconfig" bash "$INSTALL" >"$T/out10" 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -e "$T/home9/hooks/pre-push" ] && [ ! -e "$T/home9/.claude/skills/ai-review" ] \
  && ok "グループ・他人が書き込める置き場所には入れない" || ng "書き込める置き場所に入れた rc=$rc $(tail -2 "$T/out10")"
chmod 755 "$T/home9/hooks"

echo "4m. 一時ファイルを置き場所に残さない"
! ls -a "$T/home/.git-hooks" | grep -q '^\.pre-push\.new' && ok "置き場所に .pre-push.new.* が残らない" || ng "一時ファイルが残った: $(ls -a "$T/home/.git-hooks")"

echo "4n. --hook-only はスキルを入れず、フックにこのリポジトリのスキルの場所を埋め込む"
rm -rf "$T/home10"; mkdir -p "$T/home10"
HOME="$T/home10" GIT_CONFIG_GLOBAL="$T/home10/.gitconfig" bash "$INSTALL" --hook-only >"$T/out11" 2>&1; rc=$?
[ $rc -eq 0 ] && [ ! -e "$T/home10/.claude/skills/ai-review" ] && grep -qF "skill_dir=\"$(cd "$root" && pwd -P)/skills/ai-review\"" "$T/home10/.git-hooks/pre-push" 2>/dev/null \
  && ok "プラグインと組み合わせても、スキルを二重に入れない" || ng "--hook-only: rc=$rc $(tail -2 "$T/out11")"

HOME="$T/home10" GIT_CONFIG_GLOBAL="$T/home10/.gitconfig" bash "$INSTALL" --hook-only --copy >"$T/out11" 2>&1; rc=$?
[ $rc -ne 0 ] && ok "--hook-only と --copy を一緒に付けると止まる" || ng "--hook-only --copy で続行した"

echo "4p. umask 002 でも、自分で作った置き場所を 2 回目に拒まない"
rm -rf "$T/home12"; mkdir -p "$T/home12"
( umask 002; HOME="$T/home12" GIT_CONFIG_GLOBAL="$T/home12/.gitconfig" bash "$INSTALL" >"$T/out13" 2>&1 \
  && HOME="$T/home12" GIT_CONFIG_GLOBAL="$T/home12/.gitconfig" bash "$INSTALL" >>"$T/out13" 2>&1 ); rc=$?
[ $rc -eq 0 ] && [ -z "$(find "$T/home12/.git-hooks/." -maxdepth 0 -perm -0020)" ] && ok "作った置き場所はグループに書き込ませず、やり直しも通る" || ng "umask 002: rc=$rc $(tail -2 "$T/out13")"

echo "4q. 置き場所がシンボリックリンクでも、リンク先の権限で判断する"
rm -rf "$T/home13"; mkdir -p "$T/home13/real-hooks"; chmod 755 "$T/home13/real-hooks"; ln -s "$T/home13/real-hooks" "$T/home13/hooks"
HOME="$T/home13" GIT_CONFIG_GLOBAL="$T/home13/.gitconfig" git config --global core.hooksPath "$T/home13/hooks"
HOME="$T/home13" GIT_CONFIG_GLOBAL="$T/home13/.gitconfig" bash "$INSTALL" >"$T/out14" 2>&1; rc=$?
[ $rc -eq 0 ] && [ -x "$T/home13/real-hooks/pre-push" ] && ok "本人の 755 のディレクトリへのリンクなら入れる" || ng "リンクの置き場所: rc=$rc $(tail -2 "$T/out14")"

echo "4r. includeIf の中の core.hooksPath は、実行した場所に左右されない"
rm -rf "$T/home14" "$T/src14"; mkdir -p "$T/home14/cond-hooks"; GIT_CONFIG_GLOBAL=/dev/null git init -q "$T/src14"
printf '[core]\n\thooksPath = %s\n' "$T/home14/cond-hooks" > "$T/home14/cond.gitconfig"
printf '[includeIf "gitdir:%s/"]\n\tpath = %s\n' "$(cd "$T/src14" && pwd -P)" "$T/home14/cond.gitconfig" > "$T/home14/.gitconfig"
( cd "$T/src14" && HOME="$T/home14" GIT_CONFIG_GLOBAL="$T/home14/.gitconfig" bash "$INSTALL" >"$T/out15" 2>&1 ); rc=$?
[ $rc -eq 0 ] && [ -x "$T/home14/.git-hooks/pre-push" ] && [ ! -e "$T/home14/cond-hooks/pre-push" ] && grep -q 'includeIf' "$T/out15" \
  && ok "条件付きの値ではなく全体の置き場所に入れ、includeIf があることを知らせる" || ng "includeIf: rc=$rc $(tail -3 "$T/out15")"

echo "4s. 中身が同じでも、他人が書き込める pre-push は置き直す"
chmod 777 "$T/home/.git-hooks/pre-push"; inst
[ -z "$(find "$T/home/.git-hooks/pre-push" -perm -0002)" ] && [ -x "$T/home/.git-hooks/pre-push" ] && ok "書き込める mode の pre-push を置き直す" || ng "777 のまま残った"

echo "4t. 導入先のディレクトリに入れないとき、別の理由で止まったと誤って言わない"
if [ "$(id -u)" -eq 0 ]; then echo "  SKIP root では chmod 000 が効かない"; else
rm -rf "$T/home15"; mkdir -p "$T/home15/.claude/skills/ai-review"; chmod 000 "$T/home15/.claude/skills/ai-review"
HOME="$T/home15" GIT_CONFIG_GLOBAL="$T/home15/.gitconfig" bash "$INSTALL" >"$T/out16" 2>&1; rc=$?
chmod 755 "$T/home15/.claude/skills/ai-review"
[ $rc -ne 0 ] && ! grep -q '中にあります' "$T/out16" && ok "入れないことを理由に止まる" || ng "誤った理由: rc=$rc $(tail -2 "$T/out16")"
fi

echo "4u. include 先のファイルにある includeIf も知らせる"
rm -rf "$T/home16"; mkdir -p "$T/home16"
printf '[core]\n\thooksPath = /nowhere/hooks\n' > "$T/home16/cond.gitconfig"
printf '[includeIf "gitdir:/nowhere/"]\n\tpath = cond.gitconfig\n' > "$T/home16/inc.gitconfig"
printf '[include]\n\tpath = %s\n' "$T/home16/inc.gitconfig" > "$T/home16/.gitconfig"
HOME="$T/home16" GIT_CONFIG_GLOBAL="$T/home16/.gitconfig" bash "$INSTALL" >"$T/out17" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q 'includeIf' "$T/out17" && ok "入れ子の includeIf も見つける" || ng "入れ子の includeIf: rc=$rc"

echo "4u2. core.hooksPath を設定しない includeIf では知らせない"
rm -rf "$T/home21"; mkdir -p "$T/home21"
printf '[user]\n\temail = a@example.com\n' > "$T/home21/mail.gitconfig"
printf '[includeIf "gitdir:/nowhere/"]\n\tpath = %s\n' "$T/home21/mail.gitconfig" > "$T/home21/.gitconfig"
HOME="$T/home21" GIT_CONFIG_GLOBAL="$T/home21/.gitconfig" bash "$INSTALL" >"$T/out22" 2>&1; rc=$?
[ $rc -eq 0 ] && ! grep -q 'includeIf' "$T/out22" && ok "関係のない includeIf では注意を出さない" || ng "余計な注意: rc=$rc"

echo "4v. 置き場所がリンク先の無いシンボリックリンクなら、何も書き換えずに止まる"
rm -rf "$T/home17"; mkdir -p "$T/home17"; ln -s "$T/home17/missing" "$T/home17/hooks"
HOME="$T/home17" GIT_CONFIG_GLOBAL="$T/home17/.gitconfig" git config --global core.hooksPath "$T/home17/hooks"
HOME="$T/home17" GIT_CONFIG_GLOBAL="$T/home17/.gitconfig" bash "$INSTALL" >"$T/out18" 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -e "$T/home17/.claude" ] && grep -q 'リンク' "$T/out18" && ok "壊れたリンクの置き場所では止まる" || ng "壊れたリンク: rc=$rc $(tail -2 "$T/out18")"

echo "4w. 環境変数の上書きが置き場所と同じなら止めない"
rm -rf "$T/home18"; mkdir -p "$T/home18"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$T/home18/.git-hooks" \
  HOME="$T/home18" GIT_CONFIG_GLOBAL="$T/home18/.gitconfig" bash "$INSTALL" >"$T/out19" 2>&1; rc=$?
[ $rc -eq 0 ] && [ -x "$T/home18/.git-hooks/pre-push" ] && ok "同じ値の上書きなら入れる" || ng "同じ値で止まった rc=$rc $(tail -2 "$T/out19")"

GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='~/.git-hooks/' \
  HOME="$T/home18" GIT_CONFIG_GLOBAL="$T/home18/.gitconfig" bash "$INSTALL" >"$T/out19" 2>&1; rc=$?
[ $rc -eq 0 ] && ok "~ や末尾の / が違うだけの同じ場所なら止めない" || ng "~ の上書きで止まった rc=$rc $(tail -2 "$T/out19")"

echo "4v2. 置き場所が普通のファイルなら、何も書き換えずに止まる"
rm -rf "$T/home22"; mkdir -p "$T/home22"; echo x > "$T/home22/hooks"
HOME="$T/home22" GIT_CONFIG_GLOBAL="$T/home22/.gitconfig" git config --global core.hooksPath "$T/home22/hooks"
HOME="$T/home22" GIT_CONFIG_GLOBAL="$T/home22/.gitconfig" bash "$INSTALL" >"$T/out23" 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -e "$T/home22/.claude" ] && ok "ファイルの置き場所では止まる" || ng "ファイルの置き場所: rc=$rc $(tail -2 "$T/out23")"

echo "4y. 置き場所の親を他人が書き換えられるなら止める（スティッキービット付きは通す）"
rm -rf "$T/home23"; mkdir -p "$T/home23/shared/hooks"; chmod 755 "$T/home23/shared/hooks"; chmod 777 "$T/home23/shared"
HOME="$T/home23" GIT_CONFIG_GLOBAL="$T/home23/.gitconfig" git config --global core.hooksPath "$T/home23/shared/hooks"
HOME="$T/home23" GIT_CONFIG_GLOBAL="$T/home23/.gitconfig" bash "$INSTALL" >"$T/out24" 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -e "$T/home23/shared/hooks/pre-push" ] && [ ! -e "$T/home23/.claude" ] && ok "グループが書き込める親の下には入れない" || ng "親の確認なし rc=$rc $(tail -2 "$T/out24")"
chmod 1777 "$T/home23/shared"
HOME="$T/home23" GIT_CONFIG_GLOBAL="$T/home23/.gitconfig" bash "$INSTALL" >"$T/out24" 2>&1; rc=$?
if [ "$(id -u)" -eq 0 ]; then echo "  SKIP root の持ち物は /tmp の形として通す"
else [ $rc -ne 0 ] && grep -q 'home23/shared（' "$T/out24" && ok "本人の持ち物でも、他人が書き込めるスティッキービット付きの親は止める（root の /tmp の形だけ通す）" || ng "本人のスティッキーの親を通した rc=$rc $(tail -2 "$T/out24")"; fi
chmod 755 "$T/home23/shared"
personal=0   # install.sh と同じ条件で、利用者の専用グループかを決める
if [ "$(id -gn)" = "$(id -un)" ] && [ "$(id -g)" = "$(id -u)" ] && command -v getent >/dev/null 2>&1; then
  if [ -z "$(getent group "$(id -gn)" | cut -d: -f4 | tr ',' '\n' | grep -vxF "$(id -un)")" ] \
    && [ "$(getent passwd | awk -F: -v g="$(id -g)" '$4 == g' | wc -l | tr -d ' ')" -le 1 ]; then personal=1; fi
fi
if [ $personal -eq 1 ]; then
  chgrp "$(id -g)" "$T/home23/shared"; chmod 775 "$T/home23/shared"
  HOME="$T/home23" GIT_CONFIG_GLOBAL="$T/home23/.gitconfig" bash "$INSTALL" >"$T/out24" 2>&1; rc=$?
  [ $rc -eq 0 ] && ok "利用者の専用グループで書き込める親は通す（Ubuntu などの umask 002）" || ng "専用グループで止まった rc=$rc $(tail -2 "$T/out24")"
  chmod 755 "$T/home23/shared"
else
  chgrp "$(id -g)" "$T/home23/shared"; chmod 775 "$T/home23/shared"
  HOME="$T/home23" GIT_CONFIG_GLOBAL="$T/home23/.gitconfig" bash "$INSTALL" >"$T/out24" 2>&1; rc=$?
  [ $rc -ne 0 ] && ok "共有のグループ（$(id -gn)）で書き込める親は止める" || ng "共有のグループで通った"
  chmod 755 "$T/home23/shared"
fi

echo "4y2. パスの途中のリンクを置いた場所も確かめる"
rm -rf "$T/home24"; mkdir -p "$T/home24/shared" "$T/home24/real-hooks"; chmod 755 "$T/home24/real-hooks"; chmod 777 "$T/home24/shared"
ln -s "$T/home24/real-hooks" "$T/home24/shared/hooks"
HOME="$T/home24" GIT_CONFIG_GLOBAL="$T/home24/.gitconfig" git config --global core.hooksPath "$T/home24/shared/hooks"
HOME="$T/home24" GIT_CONFIG_GLOBAL="$T/home24/.gitconfig" bash "$INSTALL" >"$T/out25" 2>&1; rc=$?
chmod 755 "$T/home24/shared"
[ $rc -ne 0 ] && [ ! -e "$T/home24/real-hooks/pre-push" ] && ok "他人が書き込める場所に置いたリンクの先には入れない" || ng "リンクを置いた場所の確認なし rc=$rc"

echo "4y3. 書き込める場所が、入れ子のリンクの途中にあっても見つける"
rm -rf "$T/home27"; mkdir -p "$T/home27/shared" "$T/home27/real"; chmod 755 "$T/home27/real"; chmod 777 "$T/home27/shared"
ln -s "$T/home27/shared" "$T/home27/L1"; ln -s "$T/home27/real" "$T/home27/shared/hooks"
HOME="$T/home27" GIT_CONFIG_GLOBAL="$T/home27/.gitconfig" git config --global core.hooksPath "$T/home27/L1/hooks"
HOME="$T/home27" GIT_CONFIG_GLOBAL="$T/home27/.gitconfig" bash "$INSTALL" >"$T/out28" 2>&1; rc=$?
chmod 755 "$T/home27/shared"
[ $rc -ne 0 ] && [ ! -e "$T/home27/real/pre-push" ] && grep -q "home27/shared（" "$T/out28" && ok "入れ子のリンクの途中の書き込める場所を名指しして止まる" || ng "入れ子のリンク: rc=$rc $(tail -2 "$T/out28")"

echo "4y4. 途中が普通のファイルなら、権限ではなくその理由で止まる"
rm -rf "$T/home28"; mkdir -p "$T/home28"; echo x > "$T/home28/notes.txt"
HOME="$T/home28" GIT_CONFIG_GLOBAL="$T/home28/.gitconfig" git config --global core.hooksPath "$T/home28/notes.txt/hooks"
HOME="$T/home28" GIT_CONFIG_GLOBAL="$T/home28/.gitconfig" bash "$INSTALL" >"$T/out29" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q 'ディレクトリではありません' "$T/out29" && [ ! -e "$T/home28/.claude" ] && ok "途中のファイルを理由に止まる" || ng "途中のファイル: rc=$rc $(tail -2 "$T/out29")"

echo "4y5. 本人が作れない置き場所なら、スキルにも設定にも触らずに止まる"
if [ "$(id -u)" -eq 0 ]; then echo "  SKIP root はどこでも作れる"; else
rm -rf "$T/home29"; mkdir -p "$T/home29/ro"; chmod 555 "$T/home29/ro"
HOME="$T/home29" GIT_CONFIG_GLOBAL="$T/home29/.gitconfig" git config --global core.hooksPath "$T/home29/ro/hooks"
HOME="$T/home29" GIT_CONFIG_GLOBAL="$T/home29/.gitconfig" bash "$INSTALL" >"$T/out30" 2>&1; rc=$?
chmod 755 "$T/home29/ro"
[ $rc -ne 0 ] && [ ! -e "$T/home29/.claude" ] && ok "置き場所を作れないときはスキルを入れない" || ng "作れない置き場所: rc=$rc $(ls -a "$T/home29" | tr '\n' ' ')"
fi

echo "4u4. includeIf の先の core.hooksPath が置き場所と同じなら知らせない"
rm -rf "$T/home30"; mkdir -p "$T/home30"
printf '[core]\n\thooksPath = %s\n' "$T/home30/.git-hooks" > "$T/home30/cond.gitconfig"
printf '[includeIf "gitdir:/nowhere/"]\n\tpath = %s\n' "$T/home30/cond.gitconfig" > "$T/home30/.gitconfig"
HOME="$T/home30" GIT_CONFIG_GLOBAL="$T/home30/.gitconfig" bash "$INSTALL" >"$T/out31" 2>&1; rc=$?
[ $rc -eq 0 ] && ! grep -q 'includeIf' "$T/out31" && ok "同じ置き場所を指す includeIf では注意を出さない" || ng "同じ置き場所で注意: rc=$rc"

echo "4z. HOME が相対パスなら、止まらなくなる前に止める"
rm -rf "$T/rel"; mkdir -p "$T/rel/h"
( cd "$T/rel" && HOME=h GIT_CONFIG_GLOBAL="$T/rel/h/.gitconfig" bash "$INSTALL" >"$T/out32" 2>&1 ) & pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 $pid 2>/dev/null || break; sleep 1; done
if kill -0 $pid 2>/dev/null; then kill $pid; ng "HOME が相対のとき 10 秒で終わらない"
else wait $pid; rc=$?; [ $rc -ne 0 ] && [ ! -e "$T/rel/h/.claude" ] && ok "相対の HOME では何も書き換えずに止まる" || ng "相対の HOME: rc=$rc"; fi

echo "4z2. ~user の形の core.hooksPath は扱わずに止まる"
rm -rf "$T/home31"; mkdir -p "$T/home31"
HOME="$T/home31" GIT_CONFIG_GLOBAL="$T/home31/.gitconfig" git config --global core.hooksPath '~bob/hooks'
HOME="$T/home31" GIT_CONFIG_GLOBAL="$T/home31/.gitconfig" bash "$INSTALL" >"$T/out33" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '~bob' "$T/out33" && [ ! -e "$T/home31/.claude" ] && ok "~user の形では何も書き換えずに止まる" || ng "~user: rc=$rc $(tail -2 "$T/out33")"

echo "4z3. GIT_CONFIG_GLOBAL が相対パスなら止める"
rm -rf "$T/rel2"; mkdir -p "$T/rel2/h"
( cd "$T/rel2" && HOME="$T/rel2/h" GIT_CONFIG_GLOBAL=h/.gitconfig bash "$INSTALL" >"$T/out34" 2>&1 ); rc=$?
[ $rc -ne 0 ] && grep -q 'GIT_CONFIG_GLOBAL' "$T/out34" && [ ! -e "$T/rel2/h/.claude" ] && ok "相対の GIT_CONFIG_GLOBAL では止まる" || ng "相対の GIT_CONFIG_GLOBAL: rc=$rc"

echo "4z4. umask 002 でも、スキルの置き場所をグループに書き込ませない"
rm -rf "$T/home32"; mkdir -p "$T/home32"
( umask 002; HOME="$T/home32" GIT_CONFIG_GLOBAL="$T/home32/.gitconfig" bash "$INSTALL" >"$T/out35" 2>&1 ); rc=$?
[ $rc -eq 0 ] && [ -z "$(find "$T/home32/.claude" "$T/home32/.claude/skills" -maxdepth 0 -perm -0020)" ] && ok "作った ~/.claude/skills はグループに書き込ませない" || ng "skills の権限: rc=$rc $(ls -ld "$T/home32/.claude/skills")"

echo "4z5. リンク先の無いリンクの pre-push も、--force なしでは置き換えない"
rm -rf "$T/home33"; mkdir -p "$T/home33/.git-hooks"; ln -s "$T/home33/mine" "$T/home33/.git-hooks/pre-push"
HOME="$T/home33" GIT_CONFIG_GLOBAL="$T/home33/.gitconfig" bash "$INSTALL" >"$T/out36" 2>&1; rc=$?
[ $rc -ne 0 ] && [ -L "$T/home33/.git-hooks/pre-push" ] && ok "壊れたリンクのフックも別のフックとして扱う" || ng "壊れたリンクを置き換えた rc=$rc"
grep -q '^grep:' "$T/out36" && ng "壊れたリンクの pre-push で grep のエラーが出る" || ok "壊れたリンクの pre-push でも grep のエラーを出さない"
HOME="$T/home33" GIT_CONFIG_GLOBAL="$T/home33/.gitconfig" bash "$INSTALL" --force >"$T/out36" 2>&1; rc=$?
[ $rc -eq 0 ] && [ -L "$(ls -d "$T/home33/.git-hooks/pre-push.bak."* | head -1)" ] && [ ! -L "$T/home33/.git-hooks/pre-push" ] && ok "--force なら壊れたリンクをリンクのまま退避する" || ng "--force の退避: rc=$rc $(ls -la "$T/home33/.git-hooks")"

echo "4z5b. リンクの pre-push は、中身が同じでもリンクのまま退避してから置き直す"
rm -rf "$T/home41"; mkdir -p "$T/home41/.git-hooks";
sed "s|__AI_REVIEW_SKILL_DIR__|$T/home41/.claude/skills/ai-review|" "$root/skills/ai-review/hooks/pre-push" > "$T/home41/mine"; chmod +x "$T/home41/mine"
ln -s "$T/home41/mine" "$T/home41/.git-hooks/pre-push"
HOME="$T/home41" GIT_CONFIG_GLOBAL="$T/home41/.gitconfig" bash "$INSTALL" >"$T/out44" 2>&1; rc=$?
[ $rc -eq 0 ] && ls "$T/home41/.git-hooks" | grep -q '^pre-push\.bak\.' && ok "リンクは退避して残す" || ng "リンクの退避: rc=$rc $(ls -la "$T/home41/.git-hooks")"

echo "4z6. CDPATH に同じ名前の場所があっても、相対パスで呼んだ install.sh は自分の場所を使う"
rm -rf "$T/decoy" "$T/home34"; mkdir -p "$T/decoy/$(basename "$root")/skills/ai-review" "$T/home34"; echo decoy > "$T/decoy/$(basename "$root")/skills/ai-review/SKILL.md"
( cd "$(dirname "$root")" && CDPATH="$T/decoy" HOME="$T/home34" GIT_CONFIG_GLOBAL="$T/home34/.gitconfig" bash "$(basename "$root")/install.sh" >"$T/out37" 2>&1 ); rc=$?
[ $rc -eq 0 ] && [ "$(cd "$T/home34/.claude/skills/ai-review" && pwd -P)" = "$(cd "$root/skills/ai-review" && pwd -P)" ] && ok "CDPATH の影響を受けない" || ng "CDPATH: rc=$rc $(tail -2 "$T/out37")"

echo "4z7. 置き場所に書き込めないなら、スキルにも設定にも触らずに止まる"
if [ "$(id -u)" -eq 0 ]; then echo "  SKIP root はどこにでも書ける"; else
rm -rf "$T/home35"; mkdir -p "$T/home35/.git-hooks"; chmod 555 "$T/home35/.git-hooks"
HOME="$T/home35" GIT_CONFIG_GLOBAL="$T/home35/.gitconfig" bash "$INSTALL" >"$T/out38" 2>&1; rc=$?
chmod 755 "$T/home35/.git-hooks"
[ $rc -ne 0 ] && [ ! -e "$T/home35/.claude" ] && [ ! -e "$T/home35/.gitconfig" ] && ok "書き込めない置き場所では何も書き換えない" || ng "書き込めない置き場所: rc=$rc $(ls -a "$T/home35" | tr '\n' ' ')"
fi

echo "4z8. GIT_CONFIG が環境にあっても、読み違えずに入れる"
rm -rf "$T/home36"; mkdir -p "$T/home36"; printf '[core]\n\thooksPath = /elsewhere\n' > "$T/home36/other.gitconfig"
GIT_CONFIG="$T/home36/other.gitconfig" HOME="$T/home36" GIT_CONFIG_GLOBAL="$T/home36/.gitconfig" bash "$INSTALL" >"$T/out39" 2>&1; rc=$?
[ $rc -eq 0 ] && [ -x "$T/home36/.git-hooks/pre-push" ] && ok "GIT_CONFIG を読み取りに混ぜない" || ng "GIT_CONFIG: rc=$rc $(tail -2 "$T/out39")"

echo "4z9. 環境変数の上書きが相対パスなら、実行した場所に関係なく止める"
rm -rf "$T/home37"; mkdir -p "$T/home37/.git-hooks"
( cd "$T/home37" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=.git-hooks \
  HOME="$T/home37" GIT_CONFIG_GLOBAL="$T/home37/.gitconfig" bash "$INSTALL" >"$T/out40" 2>&1 ); rc=$?
[ $rc -ne 0 ] && [ ! -e "$T/home37/.claude" ] && ok "相対の上書きでは止まる" || ng "相対の上書き: rc=$rc"

echo "4z10. グローバル設定を書けない・読めないなら、書き換える前に止まる"
rm -rf "$T/home38"; mkdir -p "$T/home38"; : > "$T/home38/.gitconfig.lock"
HOME="$T/home38" GIT_CONFIG_GLOBAL="$T/home38/.gitconfig" bash "$INSTALL" >"$T/out41" 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -e "$T/home38/.claude" ] && [ ! -e "$T/home38/.git-hooks" ] && grep -q 'gitconfig' "$T/out41" && ok ".lock が残っているときは何も書き換えない" || ng ".lock: rc=$rc $(ls -a "$T/home38" | tr '\n' ' ')"
rm -rf "$T/home39"; mkdir -p "$T/home39"; printf '[core\n\tbroken\n' > "$T/home39/.gitconfig"
HOME="$T/home39" GIT_CONFIG_GLOBAL="$T/home39/.gitconfig" bash "$INSTALL" >"$T/out42" 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -e "$T/home39/.claude" ] && grep -q '読めません' "$T/out42" && ok "壊れたグローバル設定では何も書き換えない" || ng "壊れた設定: rc=$rc $(tail -2 "$T/out42")"

echo "4z10b. 設定ファイルが書き込めない場所へのリンクなら、書き換える前に止まる"
if [ "$(id -u)" -eq 0 ]; then echo "  SKIP root はどこにでも書ける"; else
rm -rf "$T/home42"; mkdir -p "$T/home42/ro"; : > "$T/home42/ro/config"; chmod 555 "$T/home42/ro"; ln -s "$T/home42/ro/config" "$T/home42/.gitconfig"
HOME="$T/home42" GIT_CONFIG_GLOBAL="$T/home42/.gitconfig" bash "$INSTALL" >"$T/out45" 2>&1; rc=$?
chmod 755 "$T/home42/ro"
[ $rc -ne 0 ] && [ ! -e "$T/home42/.claude" ] && ok "リンク先の場所で書き込めるかを確かめる" || ng "リンクの設定ファイル: rc=$rc $(tail -2 "$T/out45")"
fi
rm -rf "$T/home43"; mkdir -p "$T/home43"
GIT_CONFIG_GLOBAL= HOME="$T/home43" bash "$INSTALL" >"$T/out46" 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -e "$T/home43/.claude" ] && grep -q 'GIT_CONFIG_GLOBAL' "$T/out46" && ok "空の GIT_CONFIG_GLOBAL では止まる" || ng "空の GIT_CONFIG_GLOBAL: rc=$rc"

echo "4z10c. %(prefix) の形と、設定ファイルのディレクトリが無いときは、理由を名指しして止まる"
rm -rf "$T/home44"; mkdir -p "$T/home44"
HOME="$T/home44" GIT_CONFIG_GLOBAL="$T/home44/.gitconfig" git config --global core.hooksPath '%(prefix)/hooks'
HOME="$T/home44" GIT_CONFIG_GLOBAL="$T/home44/.gitconfig" bash "$INSTALL" >"$T/out47" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q '%(prefix)' "$T/out47" && ! grep -q '相対' "$T/out47" && ok "%(prefix) の形は対応していないと伝える" || ng "%(prefix): rc=$rc $(tail -2 "$T/out47")"
rm -rf "$T/home45"; mkdir -p "$T/home45"
HOME="$T/home45" GIT_CONFIG_GLOBAL="$T/home45/nodir/config" bash "$INSTALL" >"$T/out48" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q 'ディレクトリがありません' "$T/out48" && ok "設定ファイルのディレクトリが無いと伝える" || ng "nodir: rc=$rc $(tail -2 "$T/out48")"

echo "4z12. pre-push がディレクトリへのリンクでも、--force ならフックを置く"
rm -rf "$T/home46"; mkdir -p "$T/home46/.git-hooks" "$T/home46/somedir"; ln -s "$T/home46/somedir" "$T/home46/.git-hooks/pre-push"
HOME="$T/home46" GIT_CONFIG_GLOBAL="$T/home46/.gitconfig" bash "$INSTALL" --force >"$T/out49" 2>&1; rc=$?
[ $rc -eq 0 ] && [ -f "$T/home46/.git-hooks/pre-push" ] && [ ! -L "$T/home46/.git-hooks/pre-push" ] && [ -z "$(ls -A "$T/home46/somedir")" ] && ok "リンクを退避して、フックを置く" || ng "ディレクトリへのリンク: rc=$rc $(ls -la "$T/home46/.git-hooks" "$T/home46/somedir")"

echo "4z11. --copy で入れたスキルは、umask 002 でもグループに書き込ませない"
rm -rf "$T/home40"; mkdir -p "$T/home40"
( umask 002; HOME="$T/home40" GIT_CONFIG_GLOBAL="$T/home40/.gitconfig" bash "$INSTALL" --copy >"$T/out43" 2>&1 ); rc=$?
[ $rc -eq 0 ] && [ -z "$(find "$T/home40/.claude/skills/ai-review" -perm -0020 | head -1)" ] && ok "コピーしたスキルはグループに書き込ませない" || ng "--copy の権限: rc=$rc"

echo "4v3. パスの途中にリンク先の無いリンクがあれば、何も書き換えずに止まる"
rm -rf "$T/home25"; mkdir -p "$T/home25"; ln -s "$T/home25/missing" "$T/home25/x"
HOME="$T/home25" GIT_CONFIG_GLOBAL="$T/home25/.gitconfig" git config --global core.hooksPath "$T/home25/x/hooks"
HOME="$T/home25" GIT_CONFIG_GLOBAL="$T/home25/.gitconfig" bash "$INSTALL" >"$T/out26" 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -e "$T/home25/.claude" ] && grep -q 'リンク' "$T/out26" && ok "途中の壊れたリンクでは止まる" || ng "途中の壊れたリンク: rc=$rc $(ls -a "$T/home25") $(tail -2 "$T/out26")"

echo "4u3. includeIf の条件や設定ファイルの場所に空白・日本語があっても見つける"
rm -rf "$T/home26"; mkdir -p "$T/home26/設定 dir"
printf '[core]\n\thooksPath = /nowhere/hooks\n' > "$T/home26/設定 dir/cond.gitconfig"
printf '[includeIf "gitdir:/my projects/"]\n\tpath = cond.gitconfig\n' > "$T/home26/設定 dir/main.gitconfig"
printf '[include]\n\tpath = %s\n' "$T/home26/設定 dir/main.gitconfig" > "$T/home26/.gitconfig"
HOME="$T/home26" GIT_CONFIG_GLOBAL="$T/home26/.gitconfig" bash "$INSTALL" >"$T/out27" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q 'includeIf' "$T/out27" && ok "空白・日本語を含む includeIf も見つける" || ng "空白入りの includeIf: rc=$rc"

echo "4y6. 置き場所が /tmp のような誰でも書き込める場所の下なら、消えた後に作り直されうると知らせる"
if [ -k /tmp ] && [ "$(ls -ldn /tmp/ | awk '{print $3}')" = 0 ]; then
  rm -rf "$T/home49"; mkdir -p "$T/home49"; tmph="$(mktemp -d /tmp/ai-review-hooks.XXXXXX)"
  HOME="$T/home49" GIT_CONFIG_GLOBAL="$T/home49/.gitconfig" git config --global core.hooksPath "$tmph"
  HOME="$T/home49" GIT_CONFIG_GLOBAL="$T/home49/.gitconfig" bash "$INSTALL" >"$T/out52" 2>&1; rc=$?
  rm -rf "$tmph"
  [ $rc -eq 0 ] && grep -q '作り直される' "$T/out52" && ok "/tmp の下の置き場所には注意を出す" || ng "/tmp の注意なし rc=$rc $(tail -2 "$T/out52")"
else echo "  SKIP /tmp が root のスティッキービット付きでない"; fi

echo "4x. 置き場所の途中の親も、umask 002 でグループに書き込ませない"
rm -rf "$T/home19"; mkdir -p "$T/home19"
HOME="$T/home19" GIT_CONFIG_GLOBAL="$T/home19/.gitconfig" git config --global core.hooksPath "$T/home19/a/b/hooks"
( umask 002; HOME="$T/home19" GIT_CONFIG_GLOBAL="$T/home19/.gitconfig" bash "$INSTALL" >"$T/out20" 2>&1 ); rc=$?
[ $rc -eq 0 ] && [ -z "$(find "$T/home19/a" "$T/home19/a/b" "$T/home19/a/b/hooks" -perm -0020)" ] && ok "作った親もグループに書き込ませない" || ng "親の権限: rc=$rc $(ls -ld "$T/home19/a")"

echo "4n2. 導入先の中の clone から --hook-only で入れても、その clone を消すよう勧めない"
rm -rf "$T/home47"; inner2="$T/home47/.claude/skills/ai-review"; mkdir -p "$inner2"
cp "$INSTALL" "$inner2/"; cp -R "$root/skills" "$inner2/"
HOME="$T/home47" GIT_CONFIG_GLOBAL="$T/home47/.gitconfig" bash "$inner2/install.sh" --hook-only >"$T/out50" 2>&1; rc=$?
[ $rc -eq 0 ] && ! grep -q '要らなければ消して' "$T/out50" && ok "フックが使う clone は消すよう勧めない" || ng "clone を消すよう勧めた rc=$rc"

echo "4n3. 普通に入れた後に --hook-only を実行すると、スキルが 2 つ読み込まれることを知らせる"
rm -rf "$T/home48"; mkdir -p "$T/home48"
HOME="$T/home48" GIT_CONFIG_GLOBAL="$T/home48/.gitconfig" bash "$INSTALL" >/dev/null 2>&1
HOME="$T/home48" GIT_CONFIG_GLOBAL="$T/home48/.gitconfig" bash "$INSTALL" --hook-only >"$T/out51" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q '要らなければ消して' "$T/out51" && ok "リンクで入れたスキルが残っていれば知らせる" || ng "二重読み込みの注意なし rc=$rc"

echo "4o. claude が無ければ何も書き換えずに止まる"
mkdir -p "$T/bin-noclaude"; for c in git python3 dirname date sed mktemp; do p="$(command -v "$c")" && ln -sf "$p" "$T/bin-noclaude/$c"; done
rm -rf "$T/home11"; mkdir -p "$T/home11"
PATH="$T/bin-noclaude" HOME="$T/home11" GIT_CONFIG_GLOBAL="$T/home11/.gitconfig" "$BASH" "$INSTALL" >"$T/out12" 2>&1; rc=$?
[ $rc -ne 0 ] && grep -q 'claude が見つかりません' "$T/out12" && [ ! -e "$T/home11/.claude" ] \
  && ok "必須の claude が無いと止まる" || ng "claude なしで続行した rc=$rc $(tail -2 "$T/out12")"

echo "5. 前提の確認"
grep -q "python3" "$T/out" && grep -qi "codex" "$T/out" && ok "python3 と Codex CLI の有無を表示する" || ng "前提の表示: $(head -5 "$T/out")"

[ ! -e "$root/skills/ai-review/ai-review" ] && ok "テストの後、リポジトリの中にスキルの複製ができていない" || ng "skills/ai-review/ai-review ができた"
echo "== PASS $pass / FAIL $fail =="
[ $fail -eq 0 ]
