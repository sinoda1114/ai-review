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
# 例外は 2 つ。止まる前に、フックの置き場所のディレクトリだけは作っていることがある（umask 022 で作る）。
# また、先の確認をすり抜けた失敗（設定の書き込みや最後の実効値の確認）は、入れた後に止まり、そのことを伝える。
set -euo pipefail

force=0; copy=0; hook_only=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    --copy) copy=1 ;;
    --hook-only) hook_only=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: ${a}" >&2; exit 2 ;;
  esac
done
[ $hook_only -eq 1 ] && [ $copy -eq 1 ] && { echo "--hook-only と --copy は一緒に使えません（--hook-only はスキルを入れません）" >&2; exit 2; }

# 設定の読み取りを、実行した場所や環境に左右されないようにする（GIT_CONFIG は --file の代わりになり、GIT_DIR は includeIf の判定に使われる）
unset GIT_CONFIG GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

MARK='# ai-review-managed-hook'   # このフックが入れたものかどうかを見分ける印の行
repo="$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
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

case "$HOME" in
  /*) ;;
  *) echo "HOME が絶対パスではありません（${HOME}）。絶対パスにしてから実行してください。" >&2; exit 1 ;;
esac
# git は空の GIT_CONFIG_GLOBAL を「未設定」とはみなさず、空のパスに書こうとして失敗する
if [ "${GIT_CONFIG_GLOBAL+set}" = set ] && [ -z "$GIT_CONFIG_GLOBAL" ]; then
  echo "GIT_CONFIG_GLOBAL が空で設定されています。外すか、絶対パスにしてから実行してください。" >&2; exit 1
fi
# git はこれらを実行した場所から解決するので、相対だと、読む設定と書く設定が別のファイルになる
for v in GIT_CONFIG_GLOBAL XDG_CONFIG_HOME; do
  case "${!v:-/}" in   # 空は未設定と同じ扱い
    /*) ;;
    *) echo "${v} が絶対パスではありません（${!v}）。絶対パスにしてから実行してください。" >&2; exit 1 ;;
  esac
done
skills="$HOME/.claude/skills"; dst="$skills/ai-review"
backup_root="$HOME/.claude/ai-review-backup"   # skills の外に退避する（skills の中だと二重に読み込まれる）

# 導入先に直接 clone したリポジトリから実行すると、リポジトリ自身を退避してしまう
if [ $hook_only -eq 0 ] && [ -d "$dst" ] && [ ! -L "$dst" ]; then
  real_dst="$(cd -P "$dst" 2>/dev/null && pwd -P)" && [ -n "$real_dst" ] \
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
  *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._\ -]*)   # 範囲指定はロケールで広がるので、文字を並べる
    echo "スキルの場所に扱えない文字が含まれます: ${hook_skill}（英数字・/._- と空白のみ対応）" >&2
    [ $hook_only -eq 1 ] && echo "--hook-only はこのリポジトリの場所を使うので、そうした文字を含まない場所に clone し直してください。" >&2
    exit 1 ;;
esac

# 利用者ごとの専用グループ（Ubuntu などの既定）なら、グループで書き込めても本人だけ。
# グループ名が利用者名と同じ、gid が uid と同じで、ほかのメンバーも、そのグループを主に使う利用者もいないこと（getent で確かめる。無ければ専用とみなさない）
personal_gid=""
if [ "$(id -gn)" = "$(id -un)" ] && [ "$(id -g)" = "$(id -u)" ] && command -v getent >/dev/null 2>&1; then
  if [ -z "$(getent group "$(id -gn)" | cut -d: -f4 | tr ',' '\n' | grep -vxF "$(id -un)")" ] \
    && [ "$(getent passwd | awk -F: -v g="$(id -g)" '$4 == g' | wc -l | tr -d ' ')" -le 1 ]; then personal_gid="$(id -g)"
  fi
fi
writable_by_others() {  # $1 を他人か、専用でないグループが書き込めるなら真（-H・-L でリンク先を見る）
  [ -n "$(find -H "$1" -maxdepth 0 -perm -0002 2>/dev/null)" ] && return 0
  [ -n "$(find -H "$1" -maxdepth 0 -perm -0020 2>/dev/null)" ] && [ "$(ls -ldnL "$1" | awk '{print $4}')" != "$personal_gid" ] && return 0
  return 1
}
unsafe_path() {  # 自分の持ち物でないか、他人が書き込めるなら真
  [ ! -O "$1" ] || writable_by_others "$1"
}
is_system_tmp() {  # root の持ち物でスティッキービット付き（/tmp の形）なら真。中の他人の持ち物は消せず、改名もできない
  [ "$(ls -ldnL "$1" | awk '{print $3}')" = 0 ] && [ -n "$(find -H "$1" -maxdepth 0 -perm -1000 2>/dev/null)" ]
}
unsafe_dir() {  # 親として危ないなら真。本人か root の持ち物で、他人が書き込めない（または /tmp の形）なら安全
  local uid; uid="$(ls -ldnL "$1" | awk '{print $3}')"
  [ "$uid" = "$(id -u)" ] || [ "$uid" = 0 ] || return 0
  is_system_tmp "$1" && return 1
  writable_by_others "$1" && return 0
  return 1
}
unsafe_route() {  # 置き場所までを / から 1 要素ずつたどる（リンクは中身を展開して続ける。カーネルがパスを解決する順と同じ）。
                  # 通るディレクトリが危ないか、リンクの持ち主が本人・root でなければ、その場所と理由を出して真
  local cur=/ rest="$1" comp next target hops=0 uid
  if unsafe_dir /; then printf '%s' "/（持ち主か権限）"; return 0; fi
  while [ -n "$rest" ]; do
    rest="${rest#/}"; comp="${rest%%/*}"
    if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$comp" in ""|.) continue ;; ..) cur="$(dirname "$cur")"; continue ;; esac
    next="${cur%/}/$comp"
    if [ -L "$next" ]; then
      hops=$((hops + 1))
      [ $hops -le 40 ] || { printf '%s' "${next}（リンクが多すぎます）"; return 0; }
      uid="$(ls -ldn "$next" | awk '{print $3}')"
      [ "$uid" = "$(id -u)" ] || [ "$uid" = 0 ] || { printf '%s' "${next}（リンクの持ち主が本人でも root でもありません）"; return 0; }
      target="$(readlink "$next")"
      case "$target" in /*) cur=/ ;; esac   # 相対のリンクは、リンクを置いた場所から
      rest="$target${rest:+/$rest}"
      continue
    fi
    [ -e "$next" ] || return 1   # ここから先はまだ無い（umask 022 で作る）
    [ -d "$next" ] || { printf '%s' "${next}（ディレクトリではありません）"; return 0; }
    if unsafe_dir "$next"; then printf '%s' "${next}（持ち主か権限）"; return 0; fi
    cur="$next"
  done
  return 1
}
broken_link_in() {  # $1 かその途中に、リンク先の無いシンボリックリンクがあれば、それを出して真
  local d="$1"
  while [ "$d" != / ] && [ "$d" != . ]; do
    if [ -L "$d" ] && [ ! -e "$d" ]; then printf '%s' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}
norm_path() {  # git と同じく先頭の ~ と ~/ を展開し、末尾の / を落とす（~user の形は展開しない。呼ぶ前に止める）
  local v="$1"
  case "$v" in "~") v="$HOME" ;; "~/"*) v="$HOME/${v#\~/}" ;; esac
  [ "$v" = / ] || v="${v%/}"
  printf '%s' "$v"
}
same_place() {  # 2 つの書き方が同じ場所を指すなら真（あるディレクトリは実体の形で比べる。相対パスは git がリポジトリごとに解決するので、同じとみなさない）
  local a b; a="$(norm_path "$1")"; b="$(norm_path "$2")"
  case "$a" in /*) ;; *) return 1 ;; esac
  case "$b" in /*) ;; *) return 1 ;; esac
  [ "$a" = "$b" ] && return 0
  [ -d "$a" ] && [ -d "$b" ] && [ "$(cd -P "$a" && pwd -P)" = "$(cd -P "$b" && pwd -P)" ]   # cd -P: .. をリンクの先で解決する
}

# フックの置き場所を決める（まだ書き換えない）
# --global では include を既定でたどらないので、--includes を付ける。
# リポジトリの外（/）で読み、includeIf の条件で実行した場所ごとに値が変わらないようにする
# 終了コード 1 は「未設定」。それ以外（書式の誤り・読めない include など）は、書き換える前に止める
hooks="$(cd / && git config --global --includes --get core.hooksPath)" && rc=0 || rc=$?
if [ $rc -ne 0 ] && [ $rc -ne 1 ]; then
  echo "グローバルの git の設定を読めません（git config の終了コード ${rc}）。設定ファイルの書式と権限を確かめてから実行してください。" >&2
  exit 1
fi
case "$hooks" in
  "~"|"~/"*) ;;
  "~"*|"%("*) echo "グローバルの core.hooksPath の ~user や %(prefix) の形（${hooks}）には対応していません。絶対パスで設定し直してから実行してください。" >&2; exit 1 ;;
esac
hooks="$(norm_path "$hooks")"
set_hooks_path=0
if [ -z "$hooks" ]; then
  hooks="$HOME/.git-hooks"; set_hooks_path=1
  # 後で core.hooksPath を書く設定ファイルに、書き換える前に書けることを確かめる（git と同じ選び方）
  gcfg="${GIT_CONFIG_GLOBAL:-$HOME/.gitconfig}"
  xdg_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
  if [ -z "${GIT_CONFIG_GLOBAL:-}" ] && [ ! -e "$gcfg" ] && [ -e "$xdg_cfg" ]; then gcfg="$xdg_cfg"; fi
  # git はリンクをたどり、リンク先の隣に .lock を作って置き換えるので、リンク先の場所で確かめる
  hops=0
  while [ -L "$gcfg" ] && [ $hops -lt 40 ]; do
    t="$(readlink "$gcfg")"; hops=$((hops + 1))
    case "$t" in /*) gcfg="$t" ;; *) gcfg="$(dirname "$gcfg")/$t" ;; esac
  done
  if [ ! -d "$(dirname "$gcfg")" ]; then
    echo "グローバルの git の設定を書くディレクトリがありません（$(dirname "$gcfg")）。作ってから実行してください。" >&2
    exit 1
  fi
  if [ -e "$gcfg.lock" ] || { [ -e "$gcfg" ] && [ ! -r "$gcfg" ]; } || [ ! -w "$(dirname "$gcfg")" ]; then
    echo "グローバルの git の設定（${gcfg}）に書き込めません（${gcfg}.lock が残っているか、権限が足りません）。直してから実行してください。" >&2
    exit 1
  fi
else
  case "$hooks" in
    /*) ;;
    *) echo "グローバルの core.hooksPath が相対パスです（${hooks}）。git はこれをリポジトリごとに解決するので、" >&2
       echo "ここに入れても他のリポジトリではゲートが効きません。絶対パスに設定し直してから実行してください。" >&2
       exit 1 ;;
  esac
fi
# 置き場所をグループや他人が書き換えられると、フックを差し替えられる
if broken="$(broken_link_in "$hooks")"; then
  echo "フックの置き場所（${hooks}）の途中の ${broken} が、リンク先の無いシンボリックリンクです。リンク先を作るか、core.hooksPath を直してから実行してください。" >&2
  exit 1
fi
if [ -e "$hooks" ] && [ ! -d "$hooks" ]; then
  echo "フックの置き場所（${hooks}）がディレクトリではありません。core.hooksPath を直してから実行してください。" >&2
  exit 1
fi
if problem="$(unsafe_route "$hooks")"; then
  echo "フックの置き場所（${hooks}）までの途中に問題があります: ${problem}" >&2
  echo "自分か root の持ち物でないか、他人（専用でないグループを含む）が書き込める場所があると、置き場所ごと差し替えられます。直すか別の場所にしてください。" >&2
  exit 1
fi
# /tmp の形の場所を通るなら、置き場所が消えた後に他人に同じ名前で作り直されうる（再起動や定期の掃除で消える）
d="$hooks"; while [ ! -e "$d" ]; do d="$(dirname "$d")"; done
d="$(cd -P "$d" 2>/dev/null && pwd -P || true)"
while [ -n "$d" ]; do
  if is_system_tmp "$d"; then
    echo "== 注意: フックの置き場所（${hooks}）が、誰でも書き込める ${d} の下にあります。消えると他人に作り直されることがあるので、ホームの下に置くことを勧めます" >&2
    break
  fi
  [ "$d" = / ] && break
  d="$(dirname "$d")"
done
if [ -e "$hooks" ] && [ ! -O "$hooks" ]; then
  echo "フックの置き場所（${hooks}）が自分の持ち物ではありません。自分の持ち物の場所に core.hooksPath を設定し直してから実行してください。" >&2
  exit 1
fi
if [ -e "$hooks" ] && unsafe_path "$hooks"; then
  echo "フックの置き場所（${hooks}）を、他人（専用でないグループを含む）が書き込めます。権限を直してから実行してください（例: chmod go-w ${hooks}）。" >&2
  exit 1
fi
# global より強い指定（GIT_CONFIG_COUNT・GIT_CONFIG_PARAMETERS・git -c）があると、ここに入れてもゲートが動かない
if scope="$(cd / && git config --show-scope --get core.hooksPath 2>/dev/null)" && [ "${scope%%$'\t'*}" = "command" ] \
  && ! same_place "${scope#*$'\t'}" "$hooks"; then
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
if { [ -e "$hooks/pre-push" ] || [ -L "$hooks/pre-push" ]; } && ! cmp -s "$new" "$hooks/pre-push"; then
  if ! grep -sqxF "$MARK" "$hooks/pre-push" && [ $force -eq 0 ]; then
    echo "別の pre-push フックがあります: $hooks/pre-push" >&2
    echo "中身を確かめてから --force で入れ直してください（元のフックは pre-push.bak.<時刻> に退避されます）。" >&2
    echo "リポジトリごとの .git/hooks/pre-push は、入れるフックが通った後に呼び継ぎます。" >&2
    exit 1
  fi
  replace_hook=1
elif [ -L "$hooks/pre-push" ]; then
  replace_hook=1   # 中身が同じでもリンクは普通のファイルで置き直すので、リンクのまま退避して残す
fi

# 置き場所を先に作り、作った後の持ち主と権限を確かめる（止まるときに、スキルや設定を書き換えずに済むように）
if [ ! -e "$hooks" ]; then
  ( umask 022; mkdir -p "$hooks" ) || { echo "フックの置き場所（${hooks}）を作れません。権限を確かめてください。" >&2; exit 1; }
  problem=""
  # 確かめてから作るまでの間に、他人が途中を先に作っていないか
  if problem="$(unsafe_route "$hooks")" || unsafe_path "$hooks"; then
    echo "== 失敗: 作ったフックの置き場所（${hooks}）か途中の持ち主・権限が想定と違います（${problem:-置き場所}）。ほかは書き換えていません" >&2
    exit 1
  fi
  echo "  フックの置き場所を作りました: ${hooks}"
fi
if [ ! -w "$hooks" ] || [ ! -x "$hooks" ]; then
  echo "フックの置き場所（${hooks}）に書き込めません。権限を確かめてから実行してください。" >&2
  exit 1
fi
if [ $replace_hook -eq 1 ] && [ ! -L "$hooks/pre-push" ] && [ ! -r "$hooks/pre-push" ]; then
  echo "${hooks}/pre-push を読めないので、退避できません。権限を確かめてから実行してください。" >&2
  exit 1
fi
if [ $replace_hook -eq 1 ] && [ -d "$hooks/pre-push" ] && [ ! -L "$hooks/pre-push" ]; then
  echo "${hooks}/pre-push がディレクトリです。中身を確かめて退避してから実行してください。" >&2
  exit 1
fi

echo "== スキルの導入"
if [ $hook_only -eq 1 ]; then
  echo "  入れません（--hook-only）。フックの案内文には ${src} の場所を書きます"
  inside_dst=0
  if real_dst="$(cd -P "$dst" 2>/dev/null && pwd -P)" && [ -n "$real_dst" ]; then
    # 導入先の実体がこのスキルそのもの（リンクで入れた後）なら、2 つ読み込まれるので知らせる
    if [ "$real_dst" != "$src" ]; then case "$src/" in "$real_dst"/*) inside_dst=1 ;; esac; fi
  fi
  if { [ -e "$dst" ] || [ -L "$dst" ]; } && [ $inside_dst -eq 0 ]; then
    echo "  注意: ${dst} も残っています。プラグインと両方あるとスキルが 2 つ読み込まれるので、要らなければ消してください" >&2
  fi
else
( umask 022; mkdir -p "$skills" )   # umask 002 でも、グループがスキルを仕込める置き場所を作らない
same=0
if [ $copy -eq 0 ] && [ -L "$dst" ] && [ "$(cd -P "$dst" && pwd -P)" = "$(cd -P "$src" && pwd -P)" ]; then same=1; fi
if [ $copy -eq 1 ] && [ -d "$dst" ] && [ ! -L "$dst" ] && diff -rq "$src" "$dst" >/dev/null 2>&1; then same=1; fi
if [ $same -eq 1 ]; then
  echo "  導入済み（変更なし）: ${dst}"
else
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    ( umask 022; mkdir -p "$backup_root" )
    mv "$dst" "$backup_root/ai-review.$ts"; echo "  既存の ${dst} を ${backup_root}/ai-review.${ts} に退避しました"
  fi
  if [ $copy -eq 1 ]; then ( umask 022; cp -R "$src" "$dst" ); echo "  コピーしました: ${dst}"
  else ln -s "$src" "$dst"; echo "  リンクしました: ${dst} → ${src}"; fi
fi
fi

echo "== pre-push フックの導入"
if [ $replace_hook -eq 1 ]; then
  cp -P "$hooks/pre-push" "$hooks/pre-push.bak.$ts"; echo "  既存の pre-push を ${hooks}/pre-push.bak.${ts} に退避しました"
fi
if [ -e "$hooks/pre-push" ] && [ ! -L "$hooks/pre-push" ] && cmp -s "$new" "$hooks/pre-push" && ! unsafe_path "$hooks/pre-push"; then
  chmod +x "$hooks/pre-push"
  echo "  導入済み（変更なし）: ${hooks}/pre-push"
else
  # 同じディレクトリに書いてから mv で置き換える（既存のフックがリンクでも、リンク先を書き換えない）
  tmp_hook="$(mktemp "$hooks/.pre-push.new.XXXXXX")"; cp "$new" "$tmp_hook"; chmod +x "$tmp_hook"
  # rename(2) で 1 回で置き換える。リンクは退避済みで、リンク自身を置き換える（mv はディレクトリへのリンクだとその中へ移す）
  (cd / && python3 -I -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$tmp_hook" "$hooks/pre-push"); tmp_hook=""
  echo "  入れました: ${hooks}/pre-push"
fi
# core.hooksPath はフックを置いた後に書く（途中で止まっても、ゲートの無い置き場所を指したままにしない）
if [ $set_hooks_path -eq 1 ]; then
  git config --global core.hooksPath "$hooks" \
    || { echo "== 失敗: core.hooksPath を書けませんでした（スキルとフックは入った状態です）。原因を直して、もう一度実行してください" >&2; exit 1; }
  echo "  core.hooksPath を ${hooks} に設定しました"
  echo "  （各リポジトリの .git/hooks/pre-push は、このフックが通った後に呼び継ぎます。pre-commit など他の種類のフックは動かなくなるので、使っている場合は ${hooks} に置いてください）"
else
  echo "  既存の core.hooksPath を使います: ${hooks}"
fi

# 実際に効く値を確かめる（書き換える前の確認をすり抜けた上書きの最後の網）
eff="$(cd / && git config --get core.hooksPath)" && rc=0 || rc=$?
if [ $rc -ne 0 ] && [ $rc -ne 1 ]; then
  echo "== 失敗: 導入の後に git の設定を読めません（終了コード ${rc}。スキルとフックは入った状態です）" >&2
  exit 1
fi
eff="$(norm_path "$eff")"
if ! same_place "$eff" "$hooks"; then
  echo "== 失敗: 実際に効く core.hooksPath は ${eff:-（未設定）} で、フックを入れた ${hooks} と違うため、ゲートが動きません" >&2
  echo "   GIT_CONFIG_COUNT・GIT_CONFIG_PARAMETERS などの環境変数や、~/.gitconfig の include を確かめてください" >&2
  echo "   （スキルとフックは入った状態で止まっています。直したら、もう一度実行してください）" >&2
  exit 1
fi

# includeIf の中で core.hooksPath を設定していると、その条件に当たるリポジトリでは別の置き場所が使われる
# includeIf の先のファイルを読み、core.hooksPath を設定しているものがあるときだけ知らせる
cond_hp=0
# -z で読むと、元のファイル名は引用符なしで NUL まで、キーと値は改行で分かれる（条件の中の空白・日本語に左右されない）。
# 条件に当たらない includeIf の先にある、さらに入れ子の includeIf は見ない
while IFS= read -r -d '' origin && IFS= read -r -d '' kv; do
  f="$(norm_path "${kv#*$'\n'}")"
  case "$f" in /*) ;; *) f="$(dirname "${origin#file:}")/$f" ;; esac   # 相対パスは、書いてある設定ファイルからの位置
  v="$(cd / && git config --file "$f" --includes --get core.hooksPath 2>/dev/null || true)"
  if [ -n "$v" ] && ! same_place "$v" "$hooks"; then cond_hp=1; fi
done < <(cd / && git config --global --includes --show-origin -z --get-regexp '^includeif\..*\.path$' 2>/dev/null || true)
if [ $cond_hp -eq 1 ]; then
  echo "== 注意: グローバルの設定の includeIf の先で、別の core.hooksPath を設定しています。条件に当たるリポジトリでは、そちらの置き場所が使われてゲートが動かないことがあります" >&2
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
