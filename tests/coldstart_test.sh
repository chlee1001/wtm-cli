#!/usr/bin/env bash
# Cold-start UX: empty project -> wtm init -> doctor -> status, all without reading source.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "${HERE}")"; WTM="${ROOT}/bin/wtm"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
PROJ="${WORK}/newproj"; mkdir -p "${PROJ}"
git -C "${PROJ}" init -q  # make repo "." resolve to a git repo (init scaffolds repo:".")

run(){ ( cd "${PROJ}" && "${WTM}" "$@" ); }
pass=0; fail=0
check(){ if [[ "$2" == "$3" ]]; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1"; echo "       got:[$2] want:[$3]"; fail=$((fail+1)); fi; }
has(){ if echo "$2" | grep -q "$3"; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1 (missing '$3')"; echo "$2"|sed 's/^/    /'; fail=$((fail+1)); fi; }

echo "== help works before any config =="
check "help exits 0" "$(run help >/dev/null 2>&1; echo $?)" "0"

echo "== init scaffolds config =="
out="$(run init 2>&1)"
has "init reports created" "$out" "Created"
check "config file exists" "$([[ -f "${PROJ}/.wtm/config.json" ]] && echo yes)" "yes"
check "config is valid JSON" "$(jq -e . "${PROJ}/.wtm/config.json" >/dev/null 2>&1 && echo ok)" "ok"
check "init refuses to clobber" "$(run init >/dev/null 2>&1; echo $?)" "1"

echo "== doctor validates the scaffold =="
dout="$(run doctor 2>&1)"; drc=$?
has "doctor OK" "$dout" "doctor: OK"
check "doctor exit 0 on valid" "$drc" "0"

echo "== status renders on a fresh project =="
sout="$(run status 2>&1)"
has "status header" "$sout" "SLOT"
has "status reserved slot0" "$sout" "develop\|main\|newproj"

echo "== doctor catches a bad peer reference =="
jq '.components.web = {"repo":".","ports":{"http":8000},"start":"echo {peer.ghost.port.http}","runtime":"managed"}' \
  "${PROJ}/.wtm/config.json" > "${PROJ}/.wtm/c2.json" && mv "${PROJ}/.wtm/c2.json" "${PROJ}/.wtm/config.json"
check "doctor fails on unknown peer" "$(run doctor >/dev/null 2>&1; echo $?)" "1"
has "doctor names the bad ref" "$(run doctor 2>&1 || true)" "unknown peer component 'ghost'"

echo; echo "RESULT: pass=${pass} fail=${fail}"; [[ ${fail} -eq 0 ]]
