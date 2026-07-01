#!/usr/bin/env bash
# CLI e2e: bin/wtm drives create->list->status->slots->enter->stop->delete via config.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "${HERE}")"; WTM="${ROOT}/bin/wtm"

WORK="$(mktemp -d)"; PROJ="${WORK}/proj"; REPO="${PROJ}/repo"
mkdir -p "${PROJ}/.wtm" "${REPO}"
cat > "${PROJ}/.wtm/config.json" <<'CFG'
{ "project":"cli", "baseBranch":"develop", "maxSlots":5,
  "ticketPattern":"^[A-Z]+-[0-9]+$", "sessionPrefix":"clitest-",
  "components": { "svc": { "repo":"repo", "ports":{"http":39100},
    "start":"sleep 300", "health":"{port.http}", "runtime":"managed" } } }
CFG
git -C "${REPO}" init -q; git -C "${REPO}" config user.email t@t; git -C "${REPO}" config user.name t
git -C "${REPO}" checkout -q -b develop; echo app > "${REPO}/README.md"
git -C "${REPO}" add -A; git -C "${REPO}" commit -qm init

# run wtm from a SUBDIR to prove project-root discovery walks up
SUB="${REPO}"; cd "${SUB}"
run(){ ( cd "${SUB}" && "${WTM}" "$@" ); }
cleanup(){ tmux kill-session -t clitest-1-svc 2>/dev/null || true; rm -rf "${WORK}"; }
trap cleanup EXIT

pass=0; fail=0
check(){ if [[ "$2" == "$3" ]]; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1"; echo "       got:  [$2]"; echo "       want: [$3]"; fail=$((fail+1)); fi; }
has(){ if echo "$2" | grep -q "$3"; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1 (missing '$3')"; echo "$2" | sed 's/^/       /'; fail=$((fail+1)); fi; }

echo "== create (root discovery from subdir) =="
out="$(run create svc feature ABC-1 my-feature 2>&1)"
has "create reports worktree" "$out" "Created \[svc\]"
check "worktree exists" "$([[ -d "${PROJ}/repo.worktrees/feature/ABC-1" ]] && echo yes)" "yes"
check "branch created" "$(git -C "${PROJ}/repo.worktrees/feature/ABC-1" branch --show-current)" "feature/ABC-1_my-feature"

echo "== list / slots / status =="
has "list shows ticket" "$(run list 2>&1)" "ABC-1"
has "list --compact"    "$(run list --compact 2>&1)" "svc:LIVE"
has "slots shows port"  "$(run slots 2>&1)" "svc.http=39101"
has "status shows slot1" "$(run status 2>&1)" "ABC-1"

echo "== enter =="
has "enter prints path" "$(run enter ABC-1 2>&1)" "repo.worktrees/feature/ABC-1"

echo "== run -> status RUNNING-ish -> stop =="
run run ABC-1 >/dev/null 2>&1 || true
sleep 1
has "status after run (STARTING or RUNNING)" "$(run status ABC-1 2>&1)" "svc:"
run stop ABC-1 >/dev/null 2>&1
check "tmux gone after stop" "$(tmux has-session -t clitest-1-svc 2>/dev/null && echo yes || echo no)" "no"

echo "== delete =="
run delete ABC-1 --prune-branch >/dev/null 2>&1
check "worktree removed" "$([[ -d "${PROJ}/repo.worktrees/feature/ABC-1" ]] && echo yes || echo no)" "no"
has "list empty after delete" "$(run list 2>&1)" "No worktrees"

echo "== bad input =="
check "unknown command exits nonzero" "$(run frobnicate >/dev/null 2>&1; echo $?)" "1"
check "bad ticket rejected" "$(run status 'bad ticket!' >/dev/null 2>&1; echo $?)" "1"

echo; echo "RESULT: pass=${pass} fail=${fail}"; [[ ${fail} -eq 0 ]]
