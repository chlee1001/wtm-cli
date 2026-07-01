#!/usr/bin/env bash
# Config-driven slot ledger: assign/get/release/find + exhaustion + reuse.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "${HERE}")"
source "${ROOT}/lib/config.sh"; source "${ROOT}/lib/state.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/.wtm"
cat > "${WORK}/.wtm/config.json" <<'CFG'
{ "project":"t", "maxSlots":5,
  "components": { "a": { "repo":"a", "ports": { "http":8000 } } } }
CFG
export WTM_PROJECT_ROOT="${WORK}"
load_config

pass=0; fail=0
check(){ if [[ "$2" == "$3" ]]; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1"; echo "       got:  $2"; echo "       want: $3"; fail=$((fail+1)); fi; }

echo "== assignment =="
check "assign FOO-1"        "$(get_or_assign_slot FOO-1)" "1 assigned"
check "assign FOO-2"        "$(get_or_assign_slot FOO-2)" "2 assigned"
check "reassign FOO-1"      "$(get_or_assign_slot FOO-1)" "1 existing"
check "get FOO-2"           "$(get_slot_for_ticket FOO-2)" "2"
check "find ticket by slot" "$(find_ticket_by_slot 2)"     "FOO-2"

echo "== exhaustion (slot 0 reserved; only 1..4 usable) =="
get_or_assign_slot FOO-3 >/dev/null   # slot 3
get_or_assign_slot FOO-4 >/dev/null   # slot 4
rc=0; get_or_assign_slot FOO-5 >/dev/null 2>&1 || rc=$?
check "5th ticket rejected (only 4 slots)" "$rc" "1"

echo "== reuse after release =="
release_slot FOO-2
check "FOO-5 reuses freed slot 2" "$(get_or_assign_slot FOO-5)" "2 assigned"

echo "== config-driven port (state no longer hardcodes) =="
check "cfg_port a http slot3" "$(cfg_port a http 3)" "8003"

echo "== slots file shape =="
check "maxSlots persisted" "$(jq -r '._meta.maxSlots' "$(slots_file)")" "5"

echo; echo "RESULT: pass=${pass} fail=${fail}"; [[ ${fail} -eq 0 ]]
