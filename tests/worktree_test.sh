#!/usr/bin/env bash
# End-to-end: real git worktree create -> seed(.claude) -> env hydrate -> remove -> slot release.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "${HERE}")"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
PROJ="${WORK}/proj"; REPO="${PROJ}/repo"
mkdir -p "${PROJ}/.wtm" "${REPO}"

cat > "${PROJ}/.wtm/config.json" <<'CFG'
{ "project":"t", "baseBranch":"develop", "maxSlots":5,
  "ticketPattern":"^[A-Z]+-[0-9]+$", "sessionPrefix":"t-slot",
  "components": {
    "svc": {
      "repo":"repo",
      "seed":[{"from":"{repoMain}/.claude","to":".claude","tag":"agent"}],
      "ports":{"http":9000},
      "env":{"file":".env.local","template":"{repoMain}/.env.local",
             "set":{"API":"http://localhost:{port.http}/api"},"requiredKeys":["API"]}
    }
  }
}
CFG

# --- build a real repo (develop branch, gitignored .claude + .env.local) ---
git -C "${REPO}" init -q
git -C "${REPO}" config user.email t@t; git -C "${REPO}" config user.name t
git -C "${REPO}" checkout -q -b develop
printf 'app\n' > "${REPO}/README.md"
printf '.claude/\n.env.local\n' > "${REPO}/.gitignore"
mkdir -p "${REPO}/.claude"; printf 'agent-cfg\n' > "${REPO}/.claude/settings.json"
printf 'API=http://localhost:9000/api\n' > "${REPO}/.env.local"
git -C "${REPO}" add -A; git -C "${REPO}" commit -qm init

export WTM_PROJECT_ROOT="${PROJ}"
source "${ROOT}/lib/worktree.sh"
load_config

pass=0; fail=0
check(){ if [[ "$2" == "$3" ]]; then echo "  ok  $1"; pass=$((pass+1)); else echo "  FAIL $1"; echo "       got:  $2"; echo "       want: $3"; fail=$((fail+1)); fi; }

echo "== create worktree for FOO-1 (feature) =="
create_worktrees "svc" feature FOO-1 "" develop true "" >/dev/null 2>&1
WP="${PROJ}/repo.worktrees/feature/FOO-1"
check "worktree dir exists"        "$([[ -d "${WP}" ]] && echo yes)" "yes"
check "worktree is live (.git)"    "$([[ -f "${WP}/.git" ]] && echo yes)" "yes"
check "branch is feature/FOO-1"    "$(git -C "${WP}" branch --show-current)" "feature/FOO-1"
check "seed copied .claude"        "$(cat "${WP}/.claude/settings.json" 2>/dev/null)" "agent-cfg"
check "env hydrated to slot port"  "$(grep '^API=' "${WP}/.env.local" | cut -d= -f2-)" "http://localhost:9001/api"
check "slot assigned"              "$(get_slot_for_ticket FOO-1)" "1"

echo "== find + enter =="
check "find_worktree_path_by_comp" "$(find_worktree_path_by_comp svc FOO-1)" "${WP}"
check "has_any_worktree"           "$(has_any_worktree FOO-1 && echo yes)" "yes"

echo "== list records =="
check "record has ticket+type+comp" "$(worktree_list_records | cut -f1,2,4)" "$(printf 'FOO-1\tfeature\tsvc')"

echo "== skip-seed by tag =="
create_worktrees "svc" fix BAR-2 "" develop true "agent" >/dev/null 2>&1
check "seed skipped when tag excluded" "$([[ -e "${PROJ}/repo.worktrees/fix/BAR-2/.claude" ]] && echo present || echo absent)" "absent"

echo "== remove + slot release =="
remove_ticket_worktrees FOO-1 true >/dev/null 2>&1
check "worktree removed"    "$([[ -d "${WP}" ]] && echo yes || echo no)" "no"
check "slot released"       "$(get_slot_for_ticket FOO-1)" ""

echo; echo "RESULT: pass=${pass} fail=${fail}"; [[ ${fail} -eq 0 ]]
