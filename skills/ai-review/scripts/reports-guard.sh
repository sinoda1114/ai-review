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
  git -C "$1" rev-parse -q --verify "$2^{commit}" >/dev/null 2>&1 || return 1   # コミットが無い（HEAD がまだ無い、など）
  ! git -C "$1" ls-tree -r --name-only "$2" >/dev/null 2>&1
}
reports_untrusted() {
  local top="$1"; shift
  local pat='(^|/)\.review-reports(/|$)' c
  [ -L "$top/.review-reports" ] && return 0
  [ "$(git -C "$top" ls-files -z 2>/dev/null | tr '\0' '\n' | grep -ciE "$pat")" != "0" ] && return 0
  [ $# -gt 0 ] || set -- HEAD
  for c in "$@"; do
    reports_unreadable "$top" "$c" && return 0
    [ "$(git -C "$top" ls-tree -r -z --name-only "$c" 2>/dev/null | tr '\0' '\n' | grep -ciE "$pat")" != "0" ] && return 0
  done
  return 1
}
