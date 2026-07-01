#!/usr/bin/env bash
# wtm slots --max N: set/validate slot count, refuse unsafe shrink, allocation honors it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "${HERE}")"; WTM="${ROOT}/bin/wtm"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
PROJ="${WORK}/p"; mkdir -p "${PROJ}/.wtm" "${PROJ}/svc"
cat > "${PROJ}/.wtm/config.json" <<'CFG'
{ "project":"p", "maxSlots":5, "ticketPattern":"^[A-Z]+-[0-9]+$",
  "components": { "svc": { "repo":"svc", "ports":{"http":8000}, "runtime":"managed" } } }
CFG
run(){ ( cd "${PROJ}" && "${WTM}" "$@" ); }
pass=0; fail=0
check(){ if [[ "$2" == "$3" ]]; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1 got:[$2] want:[$3]"; fail=$((fail+1)); fi; }
maxcfg(){ jq -r '.maxSlots' "${PROJ}/.wtm/config.json"; }

echo "== set / show =="
check "default max in slots header" "$(run slots 2>&1 | grep -c 'maxSlots: 5')" "1"
run slots --max 8 >/dev/null 2>&1
check "config maxSlots updated to 8" "$(maxcfg)" "8"
check "slots meta synced" "$(jq -r '._meta.maxSlots' "${PROJ}/.worktree-slots.json")" "8"

echo "== validation =="
check "reject non-integer" "$(run slots --max abc >/dev/null 2>&1; echo $?)" "1"
check "reject <2"          "$(run slots --max 1 >/dev/null 2>&1; echo $?)" "1"
check "unchanged after reject" "$(maxcfg)" "8"

echo "== refuse unsafe shrink (assigned slot would fall out of range) =="
# manually assign a ticket to slot 6
tmp=$(mktemp); jq '.slots["X-9"]=6' "${PROJ}/.worktree-slots.json" > "$tmp" && mv "$tmp" "${PROJ}/.worktree-slots.json"
check "shrink below assigned refused" "$(run slots --max 5 >/dev/null 2>&1; echo $?)" "1"
check "still 8 after refusal" "$(maxcfg)" "8"
# free it, then shrink ok
tmp=$(mktemp); jq 'del(.slots["X-9"])' "${PROJ}/.worktree-slots.json" > "$tmp" && mv "$tmp" "${PROJ}/.worktree-slots.json"
run slots --max 3 >/dev/null 2>&1
check "shrink to 3 ok once free" "$(maxcfg)" "3"

echo "== allocation honors new max (3 => usable 1,2 only) =="
export WTM_PROJECT_ROOT="${PROJ}"
source "${ROOT}/lib/config.sh"; source "${ROOT}/lib/state.sh"; load_config
check "assign FOO-1" "$(get_or_assign_slot FOO-1)" "1 assigned"
check "assign FOO-2" "$(get_or_assign_slot FOO-2)" "2 assigned"
check "FOO-3 rejected (max 3)" "$(get_or_assign_slot FOO-3 >/dev/null 2>&1; echo $?)" "1"

echo; echo "RESULT: pass=${pass} fail=${fail}"; [[ ${fail} -eq 0 ]]
