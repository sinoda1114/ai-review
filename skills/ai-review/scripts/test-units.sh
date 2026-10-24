#!/usr/bin/env bash
# /ai-review の小さな回帰テスト（gate.py・pre-push・run-reviews.sh の端のケース）。
# test-gate.sh より狭く速い（数秒）。実モデルは呼ばない。
#   使い方: scripts/test-units.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
GP="$here/gate.py"; HOOK="$here/../hooks/pre-push"; RR="$here/run-reviews.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/units-test.XXXXXX")" && [ -n "$T" ] && [ -d "$T" ] || { echo "mktemp 失敗" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ echo "  PASS $1"; pass=$((pass+1)); }
ng(){ echo "  FAIL $1"; fail=$((fail+1)); }
G(){ git -c user.email=t@t -c user.name=t "$@"; }

echo "1. gate.py"
# git が見つからなくても、is_ancestor は例外で落ちずに False を返す
out="$(cd "$T" && python3 -I - "$here" <<'PY' 2>&1
import sys, subprocess
sys.path.insert(0, sys.argv[1])
import gate
def boom(*a, **k):
    raise FileNotFoundError("git")
subprocess.run = boom
print(gate.is_ancestor("a" * 40, "HEAD"))
PY
)"
[ "$out" = "False" ] && ok "git が無くても is_ancestor は False を返す" || ng "is_ancestor が落ちた: $out"

# 差分レビューで全体レビューが足りないときも、未処理の項目を一緒に出す
cat > "$T/latest.json" <<'JSON'
{"version": 3, "head_sha": "h", "mode": "branch", "verdict": "must-address", "scope": "incremental", "full_count": 1,
 "must_address": [{"id": "R1", "tier": "MUST-ADDRESS", "file": "a.py", "line": 3, "status": "open"}]}
JSON
out="$(python3 "$GP" check --latest "$T/latest.json" --head h 2>&1)"; rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q '全体レビュー' && printf '%s' "$out" | grep -q 'R1'; then
  ok "差分レビューの不足と、未処理の項目を両方出す"
else
  ng "check の出力: rc=$rc $out"
fi

echo "2. run-reviews.sh"
# escalation.json の書き換えは、一時ファイルに書いてから置き換える（途中で失敗しても中途半端なファイルを残さない）
n="$(grep -c 'json.dump(d, open(' "$RR")"
[ "$n" = "0" ] && ok "escalation.json を開いたまま json.dump しない" || ng "json.dump(d, open(...)) が ${n} か所に残っている"

echo "3. pre-push"
export GIT_CONFIG_GLOBAL="$T/gitconfig"; : > "$GIT_CONFIG_GLOBAL"   # この端末のグローバルの設定に左右されない
zero=0000000000000000000000000000000000000000
mkrepo(){  # <dir>: コミット 1 つと、呼び継がれたら印を残す .git/hooks/pre-push を持つリポジトリ
  G init -q -b main "$1" && (cd "$1" && echo a > a.txt && G add a.txt && G commit -qm a) || exit 2
  printf '#!/bin/sh\nwc -l < /dev/stdin | tr -d " " > "%s/chained"\n' "$1" > "$1/.git/hooks/pre-push"; chmod +x "$1/.git/hooks/pre-push"
}
# 入力が空のときも呼び継ぎ、空行を渡さない
mkrepo "$T/r1"
(cd "$T/r1" && printf '' | bash "$HOOK" origin x >/dev/null 2>&1)
[ "$(cat "$T/r1/chained" 2>/dev/null)" = "0" ] && ok "入力が空なら、呼び継いだフックに空行を渡さない" || ng "呼び継いだフックの入力の行数: $(cat "$T/r1/chained" 2>/dev/null)"
# bare リポジトリでも、リポジトリ自身の pre-push を呼び継ぐ
G init -q --bare "$T/bare.git"; printf '#!/bin/sh\necho called > "%s/bare-chained"\n' "$T" > "$T/bare.git/hooks/pre-push"; chmod +x "$T/bare.git/hooks/pre-push"
(cd "$T/bare.git" && printf '' | bash "$HOOK" origin x >/dev/null 2>&1)
[ -f "$T/bare-chained" ] && ok "bare リポジトリでも、リポジトリ自身の pre-push を呼び継ぐ" || ng "bare リポジトリで呼び継がなかった"
# シグナルで止まっても、一時ファイルを残さない
mkrepo "$T/r2"; mkdir -p "$T/tmp"
printf '#!/bin/sh\nsleep 2\n' > "$T/r2/.git/hooks/pre-push"
printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$T/r2" rev-parse HEAD)" $zero > "$T/r2.in"
(cd "$T/r2" && AI_REVIEW_BYPASS=1 TMPDIR="$T/tmp" exec bash "$HOOK" origin x < "$T/r2.in" >/dev/null 2>&1) &   # exec: PID をフック本体にする
hp=$!; sleep 1; kill -TERM $hp 2>/dev/null; wait $hp 2>/dev/null
[ -z "$(ls -A "$T/tmp")" ] && ok "シグナルで止まっても、一時ファイルを残さない" || ng "一時ファイルが残った: $(ls "$T/tmp")"
# 索引から外しても、push するコミットに .review-reports があれば信用しない
mkrepo "$T/r3"
(cd "$T/r3" && mkdir .review-reports && echo '{}' > .review-reports/latest.json && G add .review-reports && G commit -qm r && G rm -q --cached -r .review-reports)
(cd "$T/r3" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" $zero | bash "$HOOK" origin x > "$T/r3.out" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q '追跡されています' "$T/r3.out" && ok "push するコミットに .review-reports があれば拒む" || ng "rc=$rc $(cat "$T/r3.out")"
# 3 つのスクリプトも、コミットのツリーまで見る
(cd "$T/r3" && bash "$here/resolve-item.sh" --list > "$T/r3-ri.out" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q '追跡されています' "$T/r3-ri.out" && ok "resolve-item.sh も、コミットのツリーの .review-reports を拒む" || ng "resolve-item.sh: rc=$rc $(head -2 "$T/r3-ri.out")"

echo "== PASS $pass / FAIL $fail =="
[ $fail -eq 0 ]
