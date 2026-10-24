# .review-reports を記録の置き場所として信用できるかを確かめる。run-reviews.sh・record-gate.sh・resolve-item.sh から source する。
# hooks/pre-push は ~/.git-hooks に単独で置かれ、このファイルを読めないので、同じ中身の写しを持つ（直すときは両方直す）。
#
# reports_untrusted <リポジトリのルート> [コミット...]:
#   .review-reports がシンボリックリンクか、索引か、コミット（既定は HEAD）のツリーにあれば 0（信用できない）を返す。
#   索引だけを見ると、git rm --cached で外しただけのコミット済みの .review-reports を見落とす。
#   どの階層でも、大文字小文字を区別せずに見る（macOS の既定のファイルシステムは大文字小文字を区別しない）。
#   grep -q は途中で読むのをやめ、pipefail の下で上流が SIGPIPE で失敗扱いになるので、-c で最後まで読む。
# reports_unreadable <リポジトリのルート> <コミット>: コミットはあるのに、そのツリーを読めなければ 0（読めないものは信用しない）
reports_unreadable() {
  if ! git -C "$1" rev-parse -q --verify "$2" >/dev/null 2>&1; then
    # 「まだ無い」と見なすのは、リポジトリにコミットが 1 つも無いときだけ（ref が壊れているときは信用しない）
    local any; any="$(git -C "$1" rev-list -n 1 --all 2>/dev/null)" && [ -z "$any" ] && return 1
    return 0
  fi
  git -C "$1" rev-parse -q --verify "$2^{commit}" >/dev/null 2>&1 || return 0   # 指す先はあるのに、コミットを読めない
  ! git -C "$1" ls-tree -r --name-only "$2" >/dev/null 2>&1
}
# reports_untrusted が 0 を返したときの理由: link（シンボリックリンク）・tracked（追跡されている）・unreadable（読めない）
REPORTS_WHY=""
# reports_untrusted_message: 理由に合った文言を標準エラーに出す
reports_untrusted_message() {
  if [ "$REPORTS_WHY" = "unreadable" ]; then
    echo "コミットのツリーを読めません。.review-reports が含まれていないかを確かめられないので、レビューの出力を書けません。" >&2
    echo "リポジトリが壊れていないか（git fsck）、遅延取得のオブジェクトが取れるかを確かめてください。" >&2
  else
    echo "リポジトリの .review-reports がシンボリックリンクか、git で追跡されています（サブディレクトリ・大文字小文字違いを含む）。レビューの出力を書けません。" >&2
    echo "レビュー対象のコミットに .review-reports が含まれていないか確かめてください。" >&2
  fi
}
reports_untrusted() {
  local top="$1"; shift
  local pat='(^|/)\.review-reports(/|$)' c
  REPORTS_WHY=link; [ -L "$top/.review-reports" ] && return 0
  REPORTS_WHY=tracked; [ "$(git -C "$top" ls-files -z 2>/dev/null | tr '\0' '\n' | grep -ciE "$pat")" != "0" ] && return 0
  # 綴りは違っても、ファイルシステムの上で .review-reports と同じ実体になる名前（大文字小文字・Unicode の同一視）で
  # 追跡されているものも信用しない。追跡されているパスの先頭の名前ごとに、同じ実体かを確かめる
  local first
  while IFS= read -r first; do
    [ -n "$first" ] && [ "$first" != ".review-reports" ] && [ "$top/$first" -ef "$top/.review-reports" ] && return 0
  done < <(git -C "$top" ls-files -z 2>/dev/null | tr '\0' '\n' | cut -d/ -f1 | sort -u)
  [ $# -gt 0 ] || set -- HEAD
  for c in "$@"; do
    reports_unreadable "$top" "$c" && { REPORTS_WHY=unreadable; return 0; }
    REPORTS_WHY=tracked
    [ "$(git -C "$top" ls-tree -r -z --name-only "$c" 2>/dev/null | tr '\0' '\n' | grep -ciE "$pat")" != "0" ] && return 0
  done
  return 1
}
