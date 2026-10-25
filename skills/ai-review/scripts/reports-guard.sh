# .review-reports を記録の置き場所として信用できるかを確かめる。run-reviews.sh・record-gate.sh・resolve-item.sh から source する。
# hooks/pre-push は ~/.git-hooks に単独で置かれ、このファイルを読めないので、同じ中身の写しを持つ（直すときは両方直す）。
#
# reports_untrusted <リポジトリのルート> [コミット...]:
#   .review-reports がシンボリックリンクか、索引か、コミット（既定は HEAD）のツリーにあれば 0（信用できない）を返す。
#   索引だけを見ると、git rm --cached で外しただけのコミット済みの .review-reports を見落とす。
#   どの階層でも、大文字小文字を区別せずに見る（macOS の既定のファイルシステムは大文字小文字を区別しない）。
#   grep -q は途中で読むのをやめ、pipefail の下で上流が SIGPIPE で失敗扱いになるので、-c で最後まで読む。
#   既知の限界: ファイルシステムの上での別名（同じ実体になる綴りの違う名前）の確認は、索引と作業ツリーだけで行う
#   （チェックアウトしていないコミットのツリーの名前は、ファイルシステムで比べられない）。
# record_file [<リポジトリの中のパス>]: ゲートが信用する記録（latest.json）の場所。作業ツリーごとの git のディレクトリの中
#   （.git/ai-review/latest.json。作業ツリーの別のディレクトリなら .git/worktrees/<名前>/ai-review/latest.json）。
#   チェックアウトや reset では作れない場所に置く（作業ツリーの .review-reports だと、祖先のコミットに仕込んだ偽の記録が
#   reset の後に追跡されないファイルとして残り、それでゲートを通せた）。レビューの出力（run-*）は .review-reports に置く。
record_file() {
  local gd; gd="$(git -C "${1:-.}" rev-parse --absolute-git-dir 2>/dev/null)" && [ -n "$gd" ] || return 1
  printf '%s/ai-review/latest.json\n' "$gd"
}

# record_compat_copy <記録>: 入っている pre-push フックが古い版（記録を作業ツリーの .review-reports から読む）なら、
#   知らせて、入れ直すまでの間だけ古い場所にも写しを置く。スキルはリンクで入っていてすぐ新しくなるが、フックは写しなので、
#   入れ直すまで古い版のまま残る（写しを置かないと push が必ず止まる）。新しい版のフックは古い場所を読まないので、守りは弱まらない
record_compat_copy() {
  local rec="$1" top hp hk t
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  hp="$(git config --includes --get core.hooksPath 2>/dev/null)"; hp="${hp/#\~/$HOME}"
  [ -n "$hp" ] || hp="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/hooks"
  case "$hp" in /*) ;; *) hp="$top/$hp" ;; esac
  hk="$hp/pre-push"
  { [ -f "$hk" ] && grep -qxF '# ai-review-managed-hook' "$hk" && ! grep -qxF '# ai-review-record: git-dir' "$hk"; } || return 0
  echo "注意: 入っている pre-push フック（${hk}）は古い版で、記録を作業ツリーの .review-reports から読みます。install.sh を実行し直してください（それまでの間だけ、古い場所にも記録の写しを置きます）" >&2
  mkdir -p "$top/.review-reports" 2>/dev/null || return 0
  t="$(mktemp "$top/.review-reports/latest.json.tmp.XXXXXX")" || return 0
  cp "$rec" "$t" && mv -f "$t" "$top/.review-reports/latest.json"
}

# reports_unreadable <リポジトリのルート> <コミット>: コミットはあるのに、そのツリーを読めなければ 0（読めないものは信用しない）
reports_unreadable() {
  if ! git -C "$1" rev-parse -q --verify "$2" >/dev/null 2>&1; then
    # 「まだ無い」と見なすのは、生まれる前のブランチ（HEAD が指す ref のファイルが無い）だけ。ref のファイルが
    # あるのに解決できないとき（壊れている）や、HEAD が ref を指していないときは、読めないものとして信用しない
    local ref; ref="$(git -C "$1" symbolic-ref -q "$2" 2>/dev/null)" || return 0
    [ -e "$(git -C "$1" rev-parse --path-format=absolute --git-path "$ref" 2>/dev/null)" ] && return 0
    git -C "$1" for-each-ref --format='%(refname)' "$ref" 2>/dev/null | grep -qxF "$ref" && return 0   # packed-refs にある
    return 1
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
  # 言語設定に左右されない（UTF-8 として不正なバイトの名前で、tr などが途中で止まって検査を素通りしない）
  local -x LC_ALL=C
  local top="$1"; shift
  git -C "$top" ls-files -z >/dev/null 2>&1 || { REPORTS_WHY=unreadable; return 0; }   # 索引を読めなければ信用しない
  local pat='(^|/)\.review-reports(/|$)' c
  REPORTS_WHY=link; [ -L "$top/.review-reports" ] && return 0
  REPORTS_WHY=tracked; [ "$(git -C "$top" ls-files -z 2>/dev/null | tr '\0' '\n' | grep -ciE "$pat")" != "0" ] && return 0
  # 綴りは違っても、ファイルシステムの上で .review-reports と同じ実体になる名前（大文字小文字・Unicode の同一視）で
  # 追跡されているものも信用しない。追跡されているパスの先頭の名前ごとに、同じ実体かを確かめる
  local first
  while IFS= read -r first; do
    [ -n "$first" ] && [ "$first" != ".review-reports" ] && [ "$top/$first" -ef "$top/.review-reports" ] && return 0
  done < <(git -C "$top" ls-files -z 2>/dev/null | tr '\0' '\n' | cut -d/ -f1 | LC_ALL=C sort -u)
  [ $# -gt 0 ] || set -- HEAD
  for c in "$@"; do
    reports_unreadable "$top" "$c" && { REPORTS_WHY=unreadable; return 0; }
    REPORTS_WHY=tracked
    [ "$(git -C "$top" ls-tree -r -z --name-only "$c" 2>/dev/null | tr '\0' '\n' | grep -ciE "$pat")" != "0" ] && return 0
  done
  return 1
}
