#!/usr/bin/env bash
# End-to-end test: env-file hydration makes every port-dependent key follow the slot,
# while non-port keys stay verbatim. Uses the user's real .env.local content.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "${HERE}")"
source "${ROOT}/lib/config.sh"; source "${ROOT}/lib/render.sh"; source "${ROOT}/lib/env.sh"
load_config "${ROOT}/examples/work-plus.config.json"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
seed_envfile() {
  cat > "$1/.env.local" <<'ENV'
# API
VITE_API_MOCKING=disabled
VITE_API_URL=http://localhost:9080/api
VITE_API_VERSION=v1

# Naver Map
VITE_NAVER_MAP_CLIENT_ID=test-naver-client-id

# App
VITE_APP_TITLE=WorkPlus Admin
VITE_APP_ENV=local

# Feature Flags
VITE_ENABLE_SYSTEM_ADMIN=true

# FusionAuth OAuth2 Client (VITE_ENABLE_SYSTEM_ADMIN=true 일 때만 사용)
VITE_FUSIONAUTH_BASE_URL=https://auth.example.com
VITE_FUSIONAUTH_REDIRECT_URI=http://localhost:4200/auth/fusionauth-callback
VITE_FUSIONAUTH_POST_LOGOUT_REDIRECT_URI=http://localhost:4200/login
ENV
}

pass=0; fail=0
check(){ if [[ "$2" == "$3" ]]; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1"; echo "       got:  $2"; echo "       want: $3"; fail=$((fail+1)); fi; }
val(){ grep "^$2=" "$1/.env.local" | head -1 | cut -d= -f2-; }

for slot in 0 1; do
  wt="${WORK}/slot${slot}"; mkdir -p "$wt"; seed_envfile "$wt"
  render_env web "$slot" "T-${slot}" "$wt"
  echo "== slot ${slot} =="
  srv=$((9080+slot)); vite=$((4200+slot))
  check "VITE_API_URL follows server port"       "$(val "$wt" VITE_API_URL)"                        "http://localhost:${srv}/api"
  check "FUSIONAUTH_REDIRECT_URI follows vite"    "$(val "$wt" VITE_FUSIONAUTH_REDIRECT_URI)"        "http://localhost:${vite}/auth/fusionauth-callback"
  check "FUSIONAUTH_POST_LOGOUT follows vite"     "$(val "$wt" VITE_FUSIONAUTH_POST_LOGOUT_REDIRECT_URI)" "http://localhost:${vite}/login"
  check "non-port key untouched (TITLE)"          "$(val "$wt" VITE_APP_TITLE)"                      "WorkPlus Admin"
  check "non-port key untouched (BASE_URL)"       "$(val "$wt" VITE_FUSIONAUTH_BASE_URL)"            "https://auth.example.com"
  check "non-port key untouched (NAVER)"          "$(val "$wt" VITE_NAVER_MAP_CLIENT_ID)"            "test-naver-client-id"
done

# comments/order preserved? (line 1 still the API comment, key count unchanged)
check "comment header preserved" "$(sed -n '1p' "${WORK}/slot1/.env.local")" "# API"
check "no duplicate API_URL lines" "$(grep -c '^VITE_API_URL=' "${WORK}/slot1/.env.local")" "1"

echo; echo "RESULT: pass=${pass} fail=${fail}"; [[ ${fail} -eq 0 ]]
