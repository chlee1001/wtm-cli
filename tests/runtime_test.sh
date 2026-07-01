#!/usr/bin/env bash
# runtime.sh: pure seams against work-plus config + real tmux start/status/stop.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "${HERE}")"
source "${ROOT}/lib/runtime.sh"

pass=0; fail=0
check(){ if [[ "$2" == "$3" ]]; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1"; echo "       got:  $2"; echo "       want: $3"; fail=$((fail+1)); fi; }

echo "== pure seams (work-plus config) =="
load_config "${ROOT}/examples/work-plus.config.json"
check "session_for slot2 web"   "$(session_for 2 web)" "wp-slot2-web"
check "comp_ports server slot2"  "$(comp_ports server 2 | tr '\n' '|')" "http 9082|mysql 3308|valkey 6381|"
check "render_start_cmd server"  "$(render_start_cmd server 2 IHWP-1 /wt/s)" \
  "WP_SLOT=2 SERVER_PORT=9082 VALKEY_PORT=6381 LOCAL_DB_PORT=3308 WP_VALKEY_NAME=wp-slot2-valkey ./start.sh"
check "is_managed server"        "$(is_managed server && echo yes || echo no)" "yes"
check "app is guide"             "$(component_status app 1)" "GUIDE"

echo "== real tmux lifecycle =="
WORK="$(mktemp -d)"; mkdir -p "${WORK}/.wtm" "${WORK}/wt"
BASEPORT=39000; HPORT=$((BASEPORT+1))   # slot 1
cat > "${WORK}/.wtm/config.json" <<CFG
{ "project":"rt", "maxSlots":5, "sessionPrefix":"wtmtest-",
  "components": { "svc": { "repo":"wt", "ports":{"http":${BASEPORT}},
    "start":"python3 -m http.server {port.http}", "health":"{port.http}", "runtime":"managed" } } }
CFG
export WTM_PROJECT_ROOT="${WORK}"; load_config
SESS="$(session_for 1 svc)"
cleanup(){ tmux kill-session -t "${SESS}" 2>/dev/null || true; rm -rf "${WORK}"; }
trap cleanup EXIT

check "status before start" "$(component_status svc 1)" "STOPPED"
start_component svc 1 T-1 "${WORK}/wt" >/dev/null 2>&1
check "tmux session created" "$(tmux has-session -t "${SESS}" 2>/dev/null && echo yes || echo no)" "yes"
sleep 2
check "status RUNNING (port up)" "$(component_status svc 1)" "RUNNING"
stop_slot 1 T-1 true >/dev/null 2>&1
sleep 1
check "session gone after stop" "$(tmux has-session -t "${SESS}" 2>/dev/null && echo yes || echo no)" "no"
check "status STOPPED after stop" "$(component_status svc 1)" "STOPPED"

echo; echo "RESULT: pass=${pass} fail=${fail}"; [[ ${fail} -eq 0 ]]
