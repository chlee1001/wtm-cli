#!/usr/bin/env bash
# wtm init: multi-repo subdir detection, single-repo root, empty fallback.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "${HERE}")"; WTM="${ROOT}/bin/wtm"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
pass=0; fail=0
check(){ if [[ "$2" == "$3" ]]; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1"; echo "       got:[$2] want:[$3]"; fail=$((fail+1)); fi; }

echo "== multi-repo: root not git, api(vite)+web(git) subdirs =="
M="${WORK}/multi"; mkdir -p "${M}/api" "${M}/web"
git -C "${M}/api" init -q; printf '{"dependencies":{"vite":"^5"}}' > "${M}/api/package.json"
git -C "${M}/web" init -q
( cd "${M}" && "${WTM}" init >/dev/null 2>&1 )
cfg="${M}/.wtm/config.json"
check "components = api,web"     "$(jq -r '.components|keys|sort|join(",")' "${cfg}")" "api,web"
check "api detected as vite"    "$(jq -r '.components.api.ports|keys[0]' "${cfg}")" "vite"
check "api start uses vite"     "$(jq -r '.components.api.start' "${cfg}")" "pnpm dev --port {port.vite}"
check "web generic http"        "$(jq -r '.components.web.ports.http' "${cfg}")" "9000"
check "distinct base ports"     "$(jq -r '[.components[].ports|to_entries[0].value]|unique|length' "${cfg}")" "2"
check "api repo path"           "$(jq -r '.components.api.repo' "${cfg}")" "api"

echo "== single-repo: root itself is git =="
S="${WORK}/single"; mkdir -p "${S}"; git -C "${S}" init -q
( cd "${S}" && "${WTM}" init >/dev/null 2>&1 )
check "single component, repo=."  "$(jq -r '.components[].repo' "${S}/.wtm/config.json")" "."

echo "== empty fallback: no git anywhere =="
E="${WORK}/empty"; mkdir -p "${E}"
out="$( cd "${E}" && "${WTM}" init 2>&1 )"
check "fallback placeholder app"  "$(jq -r '.components|keys[0]' "${E}/.wtm/config.json")" "app"
check "fallback warns"            "$(echo "$out" | grep -qi 'placeholder' && echo yes)" "yes"

echo; echo "RESULT: pass=${pass} fail=${fail}"; [[ ${fail} -eq 0 ]]
