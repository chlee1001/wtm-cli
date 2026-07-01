#!/usr/bin/env bash
# Regression: a symlinked `wtm` on PATH must still resolve ../lib (BASH_SOURCE symlink chase).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "${HERE}")"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
pass=0; fail=0
check(){ if [[ "$2" == "$3" ]]; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1 got:[$2]"; fail=$((fail+1)); fi; }

# 1) direct symlink
ln -s "${ROOT}/bin/wtm" "${WORK}/wtm"
check "symlinked wtm help runs" "$("${WORK}/wtm" help >/dev/null 2>&1; echo $?)" "0"
# 2) symlink-to-symlink (e.g. ~/.local/bin/wtm -> repo, then another)
ln -s "${WORK}/wtm" "${WORK}/wtm2"
check "double-symlink runs"     "$("${WORK}/wtm2" help >/dev/null 2>&1; echo $?)" "0"
# 3) relative symlink
( cd "${WORK}" && ln -s wtm wtm-rel )
check "relative symlink runs"   "$("${WORK}/wtm-rel" help >/dev/null 2>&1; echo $?)" "0"

echo; echo "RESULT: pass=${pass} fail=${fail}"; [[ ${fail} -eq 0 ]]
