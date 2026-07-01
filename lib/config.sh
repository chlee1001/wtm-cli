#!/usr/bin/env bash
# config.sh — locate and read the project's .wtm/config.json
#
# Discovery: walk up from $WTM_PROJECT_ROOT (or $PWD) until a .wtm/config.json is found,
# git-style. Exposes jq-backed accessors so the rest of the engine never hardcodes
# repo paths, ports, or commands.

# --- discovery -------------------------------------------------------------

find_config() {
  local dir="${WTM_PROJECT_ROOT:-$PWD}"
  dir="$(cd "$dir" 2>/dev/null && pwd)" || return 1
  while :; do
    if [[ -f "${dir}/.wtm/config.json" ]]; then
      printf '%s\n' "${dir}/.wtm/config.json"
      return 0
    fi
    [[ "${dir}" == "/" ]] && return 1
    dir="$(dirname "${dir}")"
  done
}

# Load config into WTM_CONFIG (file) and WTM_ROOT (project root = dir containing .wtm).
load_config() {
  local override="${1:-}"
  if [[ -n "${override}" ]]; then
    WTM_CONFIG="${override}"
  else
    WTM_CONFIG="$(find_config)" || return 1
  fi
  [[ -f "${WTM_CONFIG}" ]] || return 1
  jq -e . "${WTM_CONFIG}" >/dev/null 2>&1 || {
    echo "Error: invalid JSON in ${WTM_CONFIG}" >&2
    return 1
  }
  WTM_ROOT="$(cd "$(dirname "$(dirname "${WTM_CONFIG}")")" && pwd)"
  export WTM_CONFIG WTM_ROOT
}

# --- generic accessor ------------------------------------------------------

cfg() { jq -r "$1" "${WTM_CONFIG}"; }

# --- project-level accessors ----------------------------------------------

cfg_project()        { cfg '.project'; }
cfg_base_branch()    { cfg '.baseBranch // "main"'; }
cfg_max_slots()      { cfg '.maxSlots // 5'; }
cfg_reserved0()      { cfg '.reservedSlot0 // "develop"'; }
cfg_ticket_pattern() { cfg '.ticketPattern // "^[A-Za-z0-9][A-Za-z0-9._-]*$"'; }
cfg_session_prefix() { cfg '.sessionPrefix // "wtm-slot"'; }

cfg_components() { cfg '.components | keys[]'; }

cfg_has_component() {
  jq -e --arg c "$1" '.components[$c] != null' "${WTM_CONFIG}" >/dev/null 2>&1
}

# --- component-level accessors --------------------------------------------

cfg_comp() { # <comp> <jq-path-into-component>
  jq -r --arg c "$1" ".components[\$c]${2}" "${WTM_CONFIG}"
}

# absolute main repo dir
cfg_comp_repo_abs() {
  local rel; rel="$(cfg_comp "$1" '.repo')"
  printf '%s/%s\n' "${WTM_ROOT}" "${rel}"
}

# absolute worktree root (defaults to "<repo>.worktrees")
cfg_comp_worktree_root_abs() {
  local wr; wr="$(cfg_comp "$1" '.worktreeRoot // empty')"
  if [[ -n "${wr}" ]]; then
    printf '%s/%s\n' "${WTM_ROOT}" "${wr}"
  else
    printf '%s.worktrees\n' "$(cfg_comp_repo_abs "$1")"
  fi
}

cfg_comp_env_file()     { cfg_comp "$1" '.env.file // empty'; }
cfg_comp_env_template() { cfg_comp "$1" '.env.template // empty'; }
cfg_comp_env_required() { cfg_comp "$1" '.env.requiredKeys[]? // empty'; }
cfg_comp_env_set_keys() { cfg_comp "$1" '.env.set // {} | keys[]'; }
cfg_comp_env_set_val()  { jq -r --arg c "$1" --arg k "$2" '.components[$c].env.set[$k] // empty' "${WTM_CONFIG}"; }

cfg_comp_start()    { cfg_comp "$1" '.start // empty'; }
cfg_comp_install()  { cfg_comp "$1" '.install // empty'; }
cfg_comp_install_marker() { cfg_comp "$1" '.installMarker // empty'; }
cfg_comp_runtime()  { cfg_comp "$1" '.runtime // "managed"'; }
cfg_comp_health()   { cfg_comp "$1" '.health // empty'; }
cfg_comp_ascii_only() { cfg_comp "$1" '.asciiPathOnly // false'; }

# base port for a named port of a component (empty if undefined)
cfg_port_base() { # <comp> <portname>
  jq -r --arg c "$1" --arg p "$2" '.components[$c].ports[$p] // empty' "${WTM_CONFIG}"
}

# resolved port = base + slot
cfg_port() { # <comp> <portname> <slot>
  local base; base="$(cfg_port_base "$1" "$2")"
  [[ -n "${base}" ]] || { return 0; }
  printf '%s\n' "$(( base + $3 ))"
}

# --- seed (copy gitignored artifacts into a fresh worktree) ----------------
# git worktrees start with tracked files only; seed lists what else to copy in.
# Emits TSV lines: <from-template>\t<to-relative>\t<overwrite>\t<tag>

cfg_seed() { # project-level seed (applies to all components)
  jq -r '(.seed // [])[] |
    [ .from, .to, ((.overwrite // false)|tostring), (.tag // "") ] | @tsv' "${WTM_CONFIG}"
}

cfg_comp_seed() { # <comp> component-level seed
  jq -r --arg c "$1" '(.components[$c].seed // [])[] |
    [ .from, .to, ((.overwrite // false)|tostring), (.tag // "") ] | @tsv' "${WTM_CONFIG}"
}
