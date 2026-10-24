#!/usr/bin/env bash
# /ai-review の導入スクリプト。
#   1. 前提（git・python3・claude・codex）を確かめる
#   2. スキルを ~/.claude/skills/ai-review として入れる（このリポジトリへのシンボリックリンク）
#   3. git の pre-push フック（push 前のゲート）を、グローバルの core.hooksPath に置く
#
# 使い方: ./install.sh [--force] [--copy] [--hook-only]
#   --force      既存の別の pre-push フックがあっても、退避して入れる
#   --copy       スキルをシンボリックリンクではなくコピーで入れる（このリポジトリを消す・動かす予定があるとき）
#   --hook-only  スキルは入れず、フックだけを入れる（プラグインでスキルを入れたとき。フックの案内文には、このリポジトリのスキルの場所を書く）
#
# 何度実行しても同じ結果になる。本物の ~/.claude・~/.gitconfig を書き換えるので、内容を読んでから実行すること。
# 競合などで止まるときは、何も書き換えない（確かめる処理をすべて先に行う）。
# 例外は最後の実効値の確認だけで、先の確認をすり抜けた上書きがあると、入れた後に止まる。
set -euo pipefail

force=0; copy=0; hook_only=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    --copy) copy=1 ;;
    --hook-only) hook_only=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: ${a}" >&2; exit 2 ;;
  esac
done
[ $hook_only -eq 1 ] && [ $copy -eq 1 ] && { echo "--hook-only と --copy は一緒に使えません（--hook-only はスキルを入れません）" >&2; exit 2; }

MARK='# ai-review-managed-hook'   # このフックが入れたものかどうかを見分ける印の行
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
src="$repo/skills/ai-review"
[ -f "$src/SKILL.md" ] || { echo "スキルが見つかりません: ${src}" >&2; exit 1; }
ts="$(date +%Y%m%d%H%M%S).$$"   # 同じ秒に実行しても退避名がぶつからないように

echo "== 前提の確認"
missing=0
check() {  # <コマンド> <必須|任意> <説明>
  if command -v "$1" >/dev/null 2>&1; then echo "  ok   $1"
  elif [ "$2" = "必須" ]; then echo "  NG   $1 が見つかりません（$3）"; missing=1
  else echo "  注意 $1 が見つかりません（$3）"; fi
}
check git 必須 "git"
check python3 必須 "記録と判定に使う。標準ライブラリだけで動く"
check claude 必須 "Claude Code CLI。自前観点のレビュアーを動かす"
check codex 任意 "Codex CLI。無いと Claude 側だけになり、毎回「未取得」の項目が付く"
[ $missing -eq 0 ] || { echo "必須のコマンドが足りないため中断します" >&2; exit 1; }

skills="$HOME/.claude/skills"; dst="$skills/ai-review"
backup_root="$HOME/.claude/ai-review-backup"   # skills の外に退避する（skills の中だと二重に読み込まれる）

# 導入先に直接 clone したリポジトリから実行すると、リポジトリ自身を退避してしまう
if [ $hook_only -eq 0 ] && [ -d "$dst" ] && [ ! -L "$dst" ]; then
  real_dst="$(cd "$dst" 2>/dev/null && pwd -P)" && [ -n "$real_dst" ] \
    || { echo "スキルの導入先（${dst}）に入れません。権限を確かめてから実行してください。" >&2; exit 1; }
  case "$src/" in
    "$real_dst"/*)
      echo "このリポジトリがスキルの導入先（${dst}）の中にあります。~/.claude/skills の外に clone し直してから実行してください。" >&2
      exit 1 ;;
  esac
fi

# フックに埋め込むパス（案内文に使う）。--hook-only ではこのリポジトリのスキルの場所にする
hook_skill="$dst"; [ $hook_only -eq 1 ] && hook_skill="$src"
# フックの中では二重引用符の中に入るので、記号を含むパスは扱わない
case "$hook_skill" in
  *[!A-Za-z0-9/._\ -]*)
    echo "スキルの場所に扱えない文字が含まれます: ${hook_skill}（英数字・/._- と空白のみ対応）" >&2
    [ $hook_only -eq 1 ] && echo "--hook-only はこのリポジトリの場所を使うので、そうした文字を含まない場所に clone し直してください。" >&2
    exit 1 ;;
esac

# 利用者ごとの専用グループ（Ubuntu などの既定。グループ名が利用者名と同じ）なら、グループで書き込めても本人だけ
personal_gid=""; if [ "$(id -gn)" = "$(id -un)" ]; then personal_gid="$(id -g)"; fi
writable_by_others() {  # $1 を他人か、専用でないグループが書き込めるなら真（-H・-L でリンク先を見る）
  [ -n "$(find -H "$1" -maxdepth 0 -perm -0002 2>/dev/null)" ] && return 0
  [ -n "$(find -H "$1" -maxdepth 0 -perm -0020 2>/dev/null)" ] && [ "$(ls -ldnL "$1" | awk '{print $4}')" != "$personal_gid" ] && return 0
  return 1
}
unsafe_path() {  # 自分の持ち物でないか、他人が書き込めるなら真
  [ ! -O "$1" ] || writable_by_others "$1"
}
unsafe_parents() {  # 置き場所の親を / までたどり、他人が中身を入れ替えられる親があれば真
  local d="$1" uid
  if [ -e "$d" ]; then d="$(cd "$d" 2>/dev/null && pwd -P)" || return 0; d="$(dirname "$d")"
  else
    while [ ! -e "$d" ]; do d="$(dirname "$d")"; done   # まだ無いなら、作る場所になる一番近い親から
    d="$(cd "$d" 2>/dev/null && pwd -P)" || return 0
  fi
  while :; do
    # 本人か root の持ち物で、他人が書き込めない（またはスティッキービット付きの /tmp の形）なら安全
    uid="$(ls -ldn "$d" | awk '{print $3}')"
    [ "$uid" = "$(id -u)" ] || [ "$uid" = 0 ] || return 0
    if [ -z "$(find -H "$d" -maxdepth 0 -perm -1000 2>/dev/null)" ] && writable_by_others "$d"; then return 0; fi
    [ "$d" = / ] && return 1
    d="$(dirname "$d")"
  done
}
norm_path() {  # git と同じく先頭の ~ を展開し、末尾の / を落とす
  local v="${1/#\~/$HOME}"
  [ "$v" = / ] || v="${v%/}"
  printf '%s' "$v"
}

# フックの置き場所を決める（まだ書き換えない）
# --global では include を既定でたどらないので、--includes を付ける。
# リポジトリの外（/）で読み、includeIf の条件で実行した場所ごとに値が変わらないようにする
hooks="$(cd / && git config --global --includes --get core.hooksPath || true)"
hooks="$(norm_path "$hooks")"
set_hooks_path=0
if [ -z "$hooks" ]; then
  hooks="$HOME/.git-hooks"; set_hooks_path=1
else
  case "$hooks" in
    /*) ;;
    *) echo "グローバルの core.hooksPath が相対パスです（${hooks}）。git はこれをリポジトリごとに解決するので、" >&2
       echo "ここに入れても他のリポジトリではゲートが効きません。絶対パスに設定し直してから実行してください。" >&2
       exit 1 ;;
  esac
fi
# 置き場所をグループや他人が書き換えられると、フックを差し替えられる
if [ -L "$hooks" ] && [ ! -e "$hooks" ]; then
  echo "フックの置き場所（${hooks}）が、リンク先の無いシンボリックリンクです。リンク先を作るか、core.hooksPath を直してから実行してください。" >&2
  exit 1
fi
if [ -e "$hooks" ] && [ ! -d "$hooks" ]; then
  echo "フックの置き場所（${hooks}）がディレクトリではありません。core.hooksPath を直してから実行してください。" >&2
  exit 1
fi
if unsafe_parents "$hooks"; then
  echo "フックの置き場所（${hooks}）の親に、自分か root の持ち物でないか、他人（専用でないグループを含む）が書き込めるディレクトリがあります。置き場所ごと差し替えられるので、権限を直すか別の場所にしてください。" >&2
  exit 1
fi
if [ -e "$hooks" ] && unsafe_path "$hooks"; then
  echo "フックの置き場所（${hooks}）が自分の持ち物でないか、他人（専用でないグループを含む）が書き込めます。権限を直してから実行してください（例: chmod go-w ${hooks}）。" >&2
  exit 1
fi
# global より強い指定（GIT_CONFIG_COUNT・GIT_CONFIG_PARAMETERS・git -c）があると、ここに入れてもゲートが動かない
if scope="$(cd / && git config --show-scope --get core.hooksPath 2>/dev/null)" && [ "${scope%%$'\t'*}" = "command" ] \
  && [ "$(norm_path "${scope#*$'\t'}")" != "$hooks" ]; then
  echo "core.hooksPath が環境変数（GIT_CONFIG_COUNT・GIT_CONFIG_PARAMETERS）か git -c で ${scope#*$'\t'} に上書きされていて、ゲートが動きません。外してから実行してください。" >&2
  exit 1
fi

# 入れるフックを用意し、既存のフックとの競合を確かめる（まだ書き換えない）
new="$(mktemp "${TMPDIR:-/tmp}/ai-review-pre-push.XXXXXX")"
tmp_hook=""
trap 'rm -f "$new" ${tmp_hook:+"$tmp_hook"}' EXIT
sed "s|__AI_REVIEW_SKILL_DIR__|$hook_skill|" "$src/hooks/pre-push" > "$new"
bash -n "$new" || { echo "フックの組み立てに失敗しました" >&2; exit 1; }
replace_hook=0
if [ -e "$hooks/pre-push" ] && ! cmp -s "$new" "$hooks/pre-push"; then
  if ! grep -qxF "$MARK" "$hooks/pre-push" && [ $force -eq 0 ]; then
    echo "別の pre-push フックがあります: $hooks/pre-push" >&2
    echo "中身を確かめてから --force で入れ直してください（元のフックは pre-push.bak.<時刻> に退避されます）。" >&2
    echo "リポジトリごとの .git/hooks/pre-push は、入れるフックが通った後に呼び継ぎます。" >&2
    exit 1
  fi
  replace_hook=1
fi

echo "== スキルの導入"
if [ $hook_only -eq 1 ]; then
  echo "  入れません（--hook-only）。フックの案内文には ${src} の場所を書きます"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    echo "  注意: ${dst} も残っています。プラグインと両方あるとスキルが 2 つ読み込まれるので、要らなければ消してください" >&2
  fi
else
mkdir -p "$skills"
same=0
if [ $copy -eq 0 ] && [ -L "$dst" ] && [ "$(cd "$dst" && pwd -P)" = "$(cd "$src" && pwd -P)" ]; then same=1; fi
if [ $copy -eq 1 ] && [ -d "$dst" ] && [ ! -L "$dst" ] && diff -rq "$src" "$dst" >/dev/null 2>&1; then same=1; fi
if [ $same -eq 1 ]; then
  echo "  導入済み（変更なし）: ${dst}"
else
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    mkdir -p "$backup_root"
    mv "$dst" "$backup_root/ai-review.$ts"; echo "  既存の ${dst} を ${backup_root}/ai-review.${ts} に退避しました"
  fi
  if [ $copy -eq 1 ]; then cp -R "$src" "$dst"; echo "  コピーしました: ${dst}"
  else ln -s "$src" "$dst"; echo "  リンクしました: ${dst} → ${src}"; fi
fi
fi

echo "== pre-push フックの導入"
if [ $set_hooks_path -eq 1 ]; then
  git config --global core.hooksPath "$hooks"
  echo "  core.hooksPath を ${hooks} に設定しました"
  echo "  （各リポジトリの .git/hooks/pre-push は、このフックが通った後に呼び継ぎます。pre-commit など他の種類のフックは動かなくなるので、使っている場合は ${hooks} に置いてください）"
else
  echo "  既存の core.hooksPath を使います: ${hooks}"
fi
if [ ! -e "$hooks" ]; then
  ( umask 022; mkdir -p "$hooks" )   # umask 002 でも、途中の親を含めてグループが書き込める置き場所を作らない
fi
if [ $replace_hook -eq 1 ]; then
  cp "$hooks/pre-push" "$hooks/pre-push.bak.$ts"; echo "  既存の pre-push を ${hooks}/pre-push.bak.${ts} に退避しました"
fi
if [ -e "$hooks/pre-push" ] && [ ! -L "$hooks/pre-push" ] && cmp -s "$new" "$hooks/pre-push" && ! unsafe_path "$hooks/pre-push"; then
  chmod +x "$hooks/pre-push"
  echo "  導入済み（変更なし）: ${hooks}/pre-push"
else
  # 同じディレクトリに書いてから mv で置き換える（既存のフックがリンクでも、リンク先を書き換えない）
  tmp_hook="$(mktemp "$hooks/.pre-push.new.XXXXXX")"; cp "$new" "$tmp_hook"; chmod +x "$tmp_hook"; mv -f "$tmp_hook" "$hooks/pre-push"; tmp_hook=""
  echo "  入れました: ${hooks}/pre-push"
fi

# 実際に効く値を確かめる（書き換える前の確認をすり抜けた上書きの最後の網）
eff="$(cd / && git config --get core.hooksPath || true)"
eff="$(norm_path "$eff")"
if [ "$eff" != "$hooks" ]; then
  echo "== 失敗: 実際に効く core.hooksPath は ${eff:-（未設定）} で、フックを入れた ${hooks} と違うため、ゲートが動きません" >&2
  echo "   GIT_CONFIG_COUNT・GIT_CONFIG_PARAMETERS などの環境変数や、~/.gitconfig の include を確かめてください" >&2
  echo "   （スキルとフックは入った状態で止まっています。直したら、もう一度実行してください）" >&2
  exit 1
fi

# includeIf の中で core.hooksPath を設定していると、その条件に当たるリポジトリでは別の置き場所が使われる
# includeIf の先のファイルを読み、core.hooksPath を設定しているものがあるときだけ知らせる
cond_hp=0
while IFS=$'\t' read -r origin kv; do
  [ -n "$kv" ] || continue
  f="$(norm_path "${kv#* }")"
  case "$f" in /*) ;; *) f="$(dirname "${origin#file:}")/$f" ;; esac   # 相対パスは、書いてある設定ファイルからの位置
  if [ -n "$(git config --file "$f" --includes --get core.hooksPath 2>/dev/null)" ]; then cond_hp=1; fi
done < <(cd / && git config --global --includes --show-origin --get-regexp '^includeif\..*\.path$' 2>/dev/null || true)
if [ $cond_hp -eq 1 ]; then
  echo "== 注意: グローバルの設定の includeIf の先で core.hooksPath を設定しています。条件に当たるリポジトリでは、そちらの置き場所が使われてゲートが動きません" >&2
fi

# 実行した場所がリポジトリで、リポジトリ単位の core.hooksPath があれば、そこではゲートが動かない
if local_hp="$(git config --local --get core.hooksPath 2>/dev/null)" && [ -n "$local_hp" ]; then
  echo "== 注意: このリポジトリ（$(git rev-parse --show-toplevel)）には core.hooksPath=${local_hp} が設定されていて、ゲートが動きません" >&2
  echo "   消すなら: git config --unset core.hooksPath（リポジトリ独自のフックを使っているなら、そこに pre-push を置く）" >&2
fi

cat <<EOF
== 完了
次にすること:
  1. 各リポジトリで origin/HEAD を設定する（初回だけ）: git remote set-head origin -a
  2. .review-reports/ をグローバルの gitignore に入れておくと、レビューの出力をコミットしない
  3. Claude Code で /ai-review を実行する（push の前に 1 回。フックが結果を確かめる）
  4. レビューせずに push したいときだけ: AI_REVIEW_BYPASS=1 git push
EOF
