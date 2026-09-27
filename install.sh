#!/usr/bin/env bash
# /ai-review の導入スクリプト。
#   1. 前提（git・python3・claude・codex）を確かめる
#   2. スキルを ~/.claude/skills/ai-review として入れる（このリポジトリへのシンボリックリンク）
#   3. git の pre-push フック（push 前のゲート）を、グローバルの core.hooksPath に置く
#
# 使い方: ./install.sh [--force] [--copy]
#   --force  既存の別の pre-push フックがあっても、退避して入れる
#   --copy   スキルをシンボリックリンクではなくコピーで入れる（このリポジトリを消す・動かす予定があるとき）
#
# 何度実行しても同じ結果になる。本物の ~/.claude・~/.gitconfig を書き換えるので、内容を読んでから実行すること。
# 競合などで止まるときは、何も書き換えない（確かめる処理をすべて先に行う）。
set -euo pipefail

force=0; copy=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    --copy) copy=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: ${a}" >&2; exit 2 ;;
  esac
done

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

# フックに埋め込むパス。フックの中では二重引用符の中に入るので、記号を含むパスは扱わない
case "$dst" in
  *[!A-Za-z0-9/._\ -]*) echo "スキルの導入先に扱えない文字が含まれます: ${dst}（英数字・/._- と空白のみ対応）" >&2; exit 1 ;;
esac

# フックの置き場所を決める（まだ書き換えない）
hooks="$(git config --global --get core.hooksPath || true)"
hooks="${hooks/#\~/$HOME}"
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

# 入れるフックを用意し、既存のフックとの競合を確かめる（まだ書き換えない）
new="$(mktemp "${TMPDIR:-/tmp}/ai-review-pre-push.XXXXXX")"
trap 'rm -f "$new"' EXIT
sed "s|__AI_REVIEW_SKILL_DIR__|$dst|" "$src/hooks/pre-push" > "$new"
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

echo "== pre-push フックの導入"
if [ $set_hooks_path -eq 1 ]; then
  git config --global core.hooksPath "$hooks"
  echo "  core.hooksPath を ${hooks} に設定しました"
  echo "  （各リポジトリの .git/hooks/pre-push は、このフックが通った後に呼び継ぎます。pre-commit など他の種類のフックは動かなくなるので、使っている場合は ${hooks} に置いてください）"
else
  echo "  既存の core.hooksPath を使います: ${hooks}"
fi
mkdir -p "$hooks"
if [ $replace_hook -eq 1 ]; then
  cp "$hooks/pre-push" "$hooks/pre-push.bak.$ts"; echo "  既存の pre-push を ${hooks}/pre-push.bak.${ts} に退避しました"
fi
if [ -e "$hooks/pre-push" ] && [ ! -L "$hooks/pre-push" ] && cmp -s "$new" "$hooks/pre-push"; then
  chmod +x "$hooks/pre-push"
  echo "  導入済み（変更なし）: ${hooks}/pre-push"
else
  # 同じディレクトリに書いてから mv で置き換える（既存のフックがリンクでも、リンク先を書き換えない）
  tmp_hook="$hooks/.pre-push.new.$$"; cp "$new" "$tmp_hook"; chmod +x "$tmp_hook"; mv -f "$tmp_hook" "$hooks/pre-push"
  echo "  入れました: ${hooks}/pre-push"
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
