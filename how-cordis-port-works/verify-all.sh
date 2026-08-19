#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
fail=0
ok=0

run_one() {
  local dir="$1"
  local rel="${dir#"$ROOT"/}"
  if (
    cd "$dir"
    bash run.sh >"$ROOT/.verify-out.txt" 2>"$ROOT/.verify-err.txt"
  ); then
    echo "OK   $rel"
    ok=$((ok + 1))
  else
    echo "FAIL $rel"
    sed -n '1,30p' "$ROOT/.verify-err.txt" || true
    sed -n '1,30p' "$ROOT/.verify-out.txt" || true
    fail=$((fail + 1))
  fi
}

for d in "$ROOT"/ch*/code; do
  [[ -d "$d" ]] || continue
  run_one "$d"
done

rm -f "$ROOT/.verify-out.txt" "$ROOT/.verify-err.txt"
echo "-----"
echo "passed=$ok failed=$fail"
exit "$fail"
