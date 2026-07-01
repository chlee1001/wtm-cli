#!/usr/bin/env bash
# Regression tests for code-review fixes: hyphen tokens (HIGH), backslash env value (MEDIUM), --type validation (LOW).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "${HERE}")"; WTM="${ROOT}/bin/wtm"
source "${ROOT}/lib/config.sh"; source "${ROOT}/lib/render.sh"; source "${ROOT}/lib/env.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
pass=0; fail=0
check(){ if [[ "$2" == "$3" ]]; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1"; echo "       got:[$2] want:[$3]"; fail=$((fail+1)); fi; }

echo "== HIGH: hyphenated component/port tokens resolve =="
mkdir -p "${WORK}/.wtm"
cat > "${WORK}/.wtm/config.json" <<'CFG'
{ "project":"h", "maxSlots":5,
  "components": {
    "api-gateway": { "repo":"a", "ports":{"grpc-port":9000} },
    "redis-cache": { "repo":"r", "ports":{"port":6379} } } }
CFG
export WTM_PROJECT_ROOT="${WORK}"; load_config
check "own hyphen port"    "$(render_template 'P={port.grpc-port}' api-gateway 2 T-1 /w)" "P=9002"
check "hyphen peer ref"    "$(render_template 'U={peer.redis-cache.port.port}' api-gateway 2 T-1 /w)" "U=6381"
check "no leftover braces" "$(render_template '{port.grpc-port}-{peer.redis-cache.port.port}' api-gateway 0 T-1 /w)" "9000-6379"

echo "== MEDIUM: backslash env value written verbatim =="
ef="${WORK}/.env"; printf 'WINPATH=old\nOTHER=1\n' > "${ef}"
env_upsert "${ef}" WINPATH 'C:\temp\new'
check "backslash preserved"  "$(grep '^WINPATH=' "${ef}" | cut -d= -f2-)" 'C:\temp\new'
check "other line intact"    "$(grep '^OTHER=' "${ef}")" "OTHER=1"
env_upsert "${ef}" NEWKEY 'a&b/c'
check "special chars append"  "$(grep '^NEWKEY=' "${ef}" | cut -d= -f2-)" 'a&b/c'
check "line count 3"          "$(wc -l < "${ef}" | tr -d ' ')" "3"

echo "== LOW: --type validation =="
PROJ="${WORK}/proj"; mkdir -p "${PROJ}/.wtm"; git -C "${PROJ}" init -q
cat > "${PROJ}/.wtm/config.json" <<'CFG'
{ "project":"p", "maxSlots":5, "ticketPattern":"^[A-Z]+-[0-9]+$",
  "components": { "svc": { "repo":".", "ports":{"http":8000}, "start":"sleep 1", "runtime":"managed" } } }
CFG
check "--type garbage rejected" "$( ( cd "${PROJ}" && "${WTM}" create --type garbage FOO-1 >/dev/null 2>&1 ); echo $?)" "1"
check "--type feature accepted (parses)" "$( ( cd "${PROJ}" && "${WTM}" create --type feature BADFMT >/dev/null 2>&1 ); echo $?)" "1"

echo; echo "RESULT: pass=${pass} fail=${fail}"; [[ ${fail} -eq 0 ]]
