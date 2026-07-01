#!/usr/bin/env bash
# state.sh — slot ledger (ticket -> slot) with a mkdir-based lock.
#
# Config-driven:
#   - SLOTS_FILE derives from WTM_ROOT (project root containing .wtm/)
#   - MAX_SLOTS comes from config (cfg_max_slots)
#   - port numbers come from cfg_port <comp> <name> <slot>
# Slot 0 is the reserved baseline; tickets get slots 1..MAX_SLOTS-1.
#
# Requires config.sh sourced and load_config already run (WTM_ROOT in scope).

slots_file()     { printf '%s/.worktree-slots.json\n' "${WTM_ROOT}"; }
slots_lock_dir() { printf '%s.lock\n' "$(slots_file)"; }
max_slots()      { cfg_max_slots; }

write_default_slots_file() {
  jq -n --argjson max "$(max_slots)" '{_meta:{maxSlots:$max},slots:{}}' > "$(slots_file)"
}

ensure_slots_file() {
  local f; f="$(slots_file)"
  if [[ ! -f "${f}" ]]; then
    write_default_slots_file
    return 0
  fi
  if ! jq -e '.slots and (.slots | type == "object")' "${f}" >/dev/null 2>&1; then
    mv "${f}" "${f}.broken.$(date +%Y%m%d-%H%M%S)"
    write_default_slots_file
  fi
}

with_slots_lock() {
  local lock attempts=0 age
  lock="$(slots_lock_dir)"
  while ! mkdir "${lock}" 2>/dev/null; do
    # Recover a lock left behind by a crashed process (no owner PID to check).
    if [[ -d "${lock}" ]]; then
      age=$(( $(date +%s) - $(stat -f %m "${lock}" 2>/dev/null || stat -c %Y "${lock}" 2>/dev/null || echo 0) ))
      if (( age > 30 )); then
        echo "wtm: breaking stale slots lock (${age}s old)" >&2
        rmdir "${lock}" 2>/dev/null || true
        continue
      fi
    fi
    attempts=$((attempts + 1))
    if (( attempts >= 100 )); then
      echo "Error: could not acquire slots lock (${lock})" >&2
      return 1
    fi
    sleep 0.1
  done
  local rc=0
  "$@" || rc=$?
  rmdir "${lock}" 2>/dev/null || true
  return ${rc}
}

_get_slot_for_ticket_locked() {
  jq -r --arg t "$1" '.slots[$t] // empty' "$(slots_file)"
}
get_slot_for_ticket() { ensure_slots_file; with_slots_lock _get_slot_for_ticket_locked "$1"; }

_get_or_assign_slot_locked() {
  local ticket="$1" f slot used m tmp
  f="$(slots_file)"
  slot=$(jq -r --arg t "${ticket}" '.slots[$t] // empty' "${f}")
  if [[ -n "${slot}" ]]; then
    echo "${slot} existing"
    return 0
  fi
  used=$(jq -r '.slots | to_entries[]? | .value' "${f}" | sort -n)
  m="$(max_slots)"
  for slot in $(seq 1 $((m - 1))); do
    if ! echo "${used}" | grep -qx "${slot}"; then
      tmp=$(mktemp "${f}.tmp.XXXXXX")
      jq --arg t "${ticket}" --argjson s "${slot}" '.slots[$t] = $s' "${f}" > "${tmp}"
      mv "${tmp}" "${f}"
      echo "${slot} assigned"
      return 0
    fi
  done
  return 1
}
get_or_assign_slot() { ensure_slots_file; with_slots_lock _get_or_assign_slot_locked "$1"; }

_release_slot_locked() {
  local f tmp
  f="$(slots_file)"
  tmp=$(mktemp "${f}.tmp.XXXXXX")
  jq --arg t "$1" 'del(.slots[$t])' "${f}" > "${tmp}"
  mv "${tmp}" "${f}"
}
release_slot() { ensure_slots_file; with_slots_lock _release_slot_locked "$1"; }

find_ticket_by_slot() {
  ensure_slots_file
  jq -r --argjson s "$1" '.slots | to_entries[]? | select(.value == $s) | .key' "$(slots_file)" | head -1
}
