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

echo "== PASS $pass / FAIL $fail =="
[ $fail -eq 0 ]
