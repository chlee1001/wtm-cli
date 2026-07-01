#!/usr/bin/env bash
# Durable test for config.sh + render.sh against the work-plus reference config.
# Run: bash tests/render_test.sh   (from the wtm project root, or anywhere)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "${HERE}")"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/render.sh"
load_config "${ROOT}/examples/work-plus.config.json"

pass=0; fail=0
check() { # <label> <got> <want>
  if [[ "$2" == "$3" ]]; then echo "  ok  $1"; pass=$((pass+1))
  else echo "  FAIL $1"; echo "       got:  $2"; echo "       want: $3"; fail=$((fail+1)); fi
}

echo "== project accessors =="
check "project"       "$(cfg_project)"        "work-plus"
check "baseBranch"    "$(cfg_base_branch)"    "develop"
check "maxSlots"      "$(cfg_max_slots)"      "5"
check "sessionPrefix" "$(cfg_session_prefix)" "wp-slot"
check "components"    "$(cfg_components | sort | tr '\n' ',')" "app,server,web,"

echo "== port derivation =="
check "server http (slot2)"   "$(cfg_port server http 2)"   "9082"
check "server mysql (slot2)"  "$(cfg_port server mysql 2)"  "3308"
check "server valkey (slot2)" "$(cfg_port server valkey 2)" "6381"
check "web vite (slot3)"      "$(cfg_port web vite 3)"      "4203"

echo "== template render =="
check "server start (slot2)" \
  "$(render_template "$(cfg_comp_start server)" server 2 IHWP-1299 /wt/server)" \
  "WP_SLOT=2 SERVER_PORT=9082 VALKEY_PORT=6381 LOCAL_DB_PORT=3308 WP_VALKEY_NAME=wp-slot2-valkey ./start.sh"
check "web start (slot2)" \
  "$(render_template "$(cfg_comp_start web)" web 2 IHWP-1299 /wt/web)" \
  "VITE_PORT=4202 pnpm dev --port 4202"
check "web->server peer url (slot2)" \
  "$(render_template "$(cfg_comp web '.env.set.VITE_API_URL')" web 2 IHWP-1299 /wt/web)" \
  "http://localhost:9082/api"
check "compose project (slot4)" \
  "$(render_template "$(cfg_comp server '.compose.project')" server 4 X-1 /wt/s)" \
  "wp-slot4"

echo "== seed (copy gitignored artifacts into worktree) =="
check "web seed entry" \
  "$(cfg_comp_seed web)" \
  "$(printf '{repoMain}/.claude\t.claude\tfalse\tagent')"
# from-template renders to the component's real repo .claude
check "web seed 'from' rendered" \
  "$(render_template "$(cfg_comp_seed web | cut -f1)" web 2 IHWP-1299 /wt/web)" \
  "${WTM_ROOT}/services/work-plus-web-v2/.claude"

echo "== host env passthrough =="
export WTM_TEST_SECRET="s3cr3t"
check "shellenv token" \
  "$(render_template "TOKEN={shellenv.WTM_TEST_SECRET}" web 1 T-1 /wt/web)" \
  "TOKEN=s3cr3t"
check "home token" \
  "$(render_template "{home}/x" web 1 T-1 /wt/web)" \
  "${HOME}/x"

echo "== runtime kind =="
check "app runtime"    "$(cfg_comp_runtime app)"    "guide"
check "server runtime" "$(cfg_comp_runtime server)" "managed"

echo
echo "RESULT: pass=${pass} fail=${fail}"
[[ ${fail} -eq 0 ]]
