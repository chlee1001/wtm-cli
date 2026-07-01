#!/usr/bin/env bash
# JSON contract + GUI hardening regressions: machine output, target deltas,
# slot exhaustion atomicity, and doctor template diagnostics.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "${HERE}")"; WTM="${ROOT}/bin/wtm"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
pass=0; fail=0
check(){ if [[ "$2" == "$3" ]]; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1"; echo "       got:[$2] want:[$3]"; fail=$((fail+1)); fi; }
jqok(){ if jq -e "$2" "$3" >/dev/null; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1"; sed 's/^/       /' "$3"; fail=$((fail+1)); fi; }

make_repo() {
  local dir="$1"
  mkdir -p "${dir}"
  git -C "${dir}" init -q
  git -C "${dir}" config user.email t@t
  git -C "${dir}" config user.name t
  echo app > "${dir}/README.md"
  git -C "${dir}" add -A
  git -C "${dir}" commit -qm init
}

run_in() { # <dir> <stdout-file> <stderr-file> -- <args...>
  local dir="$1" out="$2" err="$3"; shift 3
  ( cd "${dir}" && "${WTM}" "$@" >"${out}" 2>"${err}" )
}

echo "== valid project JSON contracts =="
PROJ="${WORK}/proj"; A="${PROJ}/a"; B="${PROJ}/b"
mkdir -p "${PROJ}/.wtm"; make_repo "${A}"; make_repo "${B}"
cat > "${PROJ}/.wtm/config.json" <<'CFG'
{ "project":"json", "baseBranch":"main", "maxSlots":3, "sessionPrefix":"json-test-",
  "components": {
    "a": { "repo":"a", "ports":{"http":41000}, "start":"sleep 30", "health":"{port.http}", "runtime":"managed" },
    "b": { "repo":"b", "ports":{"http":42000}, "start":"sleep 30", "health":"{port.http}", "runtime":"managed" }
  } }
CFG

run_in "${PROJ}" "${WORK}/doctor.json" "${WORK}/doctor.err" doctor --json
jqok "doctor envelope" '.schemaVersion == 1 and .ok == true and .command == "doctor"' "${WORK}/doctor.json"
jqok "doctor tools include jq" '.data.tools[] | select(.name == "jq" and .found == true)' "${WORK}/doctor.json"

run_in "${PROJ}" "${WORK}/create-a.out" "${WORK}/create-a.err" create --target a T1
run_in "${PROJ}" "${WORK}/create-b.out" "${WORK}/create-b.err" create --target b T1
check "partial target creates a" "$([[ -d "${PROJ}/a.worktrees/feature/T1" ]] && echo yes || echo no)" "yes"
check "partial target later creates b" "$([[ -d "${PROJ}/b.worktrees/feature/T1" ]] && echo yes || echo no)" "yes"
check "single slot for partial target ticket" "$(jq -r '.slots.T1' "${PROJ}/.worktree-slots.json")" "1"

run_in "${PROJ}" "${WORK}/list.json" "${WORK}/list.err" list --json
jqok "list has two worktrees" '(.data.worktrees | length) == 2' "${WORK}/list.json"
jqok "list has component a" '.data.worktrees[] | select(.ticket == "T1" and .component == "a" and .state == "LIVE")' "${WORK}/list.json"
jqok "list has component b" '.data.worktrees[] | select(.ticket == "T1" and .component == "b" and .state == "LIVE")' "${WORK}/list.json"

run_in "${PROJ}" "${WORK}/status.json" "${WORK}/status.err" status --json
jqok "status rows include assigned slot" '.data.rows[] | select(.slot == "1" and .ticket == "T1")' "${WORK}/status.json"
jqok "status row includes components" '(.data.rows[] | select(.slot == "1") | .components | length) == 2' "${WORK}/status.json"

run_in "${PROJ}" "${WORK}/slots.json" "${WORK}/slots.err" slots --json
jqok "slots assignment has both ports" '(.data.assignments[] | select(.ticket == "T1") | .ports | length) == 2' "${WORK}/slots.json"
jqok "slots maxSlots numeric" '.data.maxSlots == 3' "${WORK}/slots.json"

echo "== machine-readable errors and atomicity =="
if run_in "${PROJ}" "${WORK}/unknown.json" "${WORK}/unknown.err" create --target nope BAD --json; then
  echo "  FAIL unknown component exits nonzero"; fail=$((fail+1))
else
  echo "  ok  unknown component exits nonzero"; pass=$((pass+1))
fi
jqok "unknown component code" '.errors[0].code == "unknown_component"' "${WORK}/unknown.json"
check "unknown component does not allocate slot" "$(jq -r '.slots.BAD // empty' "${PROJ}/.worktree-slots.json")" ""

run_in "${PROJ}" "${WORK}/create-t2.out" "${WORK}/create-t2.err" create T2
if run_in "${PROJ}" "${WORK}/slot.json" "${WORK}/slot.err" create T3 --json; then
  echo "  FAIL slot exhaustion exits nonzero"; fail=$((fail+1))
else
  echo "  ok  slot exhaustion exits nonzero"; pass=$((pass+1))
fi
jqok "slot exhaustion code" '.errors[0].code == "slot_exhausted"' "${WORK}/slot.json"
check "slot exhaustion creates no a worktree" "$([[ -d "${PROJ}/a.worktrees/feature/T3" ]] && echo yes || echo no)" "no"
check "slot exhaustion creates no b worktree" "$([[ -d "${PROJ}/b.worktrees/feature/T3" ]] && echo yes || echo no)" "no"

EMPTY="${WORK}/empty"; mkdir -p "${EMPTY}"
if run_in "${EMPTY}" "${WORK}/missing.json" "${WORK}/missing.err" status --json; then
  echo "  FAIL missing config exits nonzero"; fail=$((fail+1))
else
  echo "  ok  missing config exits nonzero"; pass=$((pass+1))
fi
jqok "missing config code" '.errors[0].code == "missing_config"' "${WORK}/missing.json"

BADJSON="${WORK}/badjson"; mkdir -p "${BADJSON}/.wtm"; printf '{ bad json\n' > "${BADJSON}/.wtm/config.json"
if run_in "${BADJSON}" "${WORK}/invalid.json" "${WORK}/invalid.err" doctor --json; then
  echo "  FAIL invalid JSON exits nonzero"; fail=$((fail+1))
else
  echo "  ok  invalid JSON exits nonzero"; pass=$((pass+1))
fi
jqok "invalid config code" '.errors[0].code == "invalid_config_json"' "${WORK}/invalid.json"

echo "== doctor template token validation =="
BADTPL="${WORK}/badtpl"; mkdir -p "${BADTPL}/.wtm"; make_repo "${BADTPL}/a"
cat > "${BADTPL}/.wtm/config.json" <<'CFG'
{ "project":"bad", "components": {
  "a": { "repo":"a", "ports":{"http":41000},
         "start":"echo {port.htp} {peer.nope.port.http} {peer.a.port.missing} {repoMainn}",
         "runtime":"managed" } } }
CFG
if run_in "${BADTPL}" "${WORK}/badtpl.json" "${WORK}/badtpl.err" doctor --json; then
  echo "  FAIL bad template doctor exits nonzero"; fail=$((fail+1))
else
  echo "  ok  bad template doctor exits nonzero"; pass=$((pass+1))
fi
jqok "template diagnostics code" '[.errors[].code] | index("invalid_template_token") != null' "${WORK}/badtpl.json"
jqok "template diagnostics identify port" '[.errors[].token] | index("port.htp") != null' "${WORK}/badtpl.json"
jqok "template diagnostics identify peer component" '[.errors[].token] | index("peer.nope.port.http") != null' "${WORK}/badtpl.json"
jqok "template diagnostics identify peer port" '[.errors[].token] | index("peer.a.port.missing") != null' "${WORK}/badtpl.json"
jqok "template diagnostics identify unknown token" '[.errors[].token] | index("repoMainn") != null' "${WORK}/badtpl.json"

echo; echo "RESULT: pass=${pass} fail=${fail}"; [[ ${fail} -eq 0 ]]
