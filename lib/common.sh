#!/usr/bin/env bash
# common.sh — colors/logging, validation, branch naming, ascii guards, seed exec.
# All helpers are config-aware (no hardcoded repo/port/command).
# Requires config.sh + render.sh sourced (and load_config run for cfg_* accessors).

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}$*${NC}"; }
warn()    { echo -e "${YELLOW}$*${NC}"; }
success() { echo -e "${GREEN}$*${NC}"; }
die()     { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }

require_cmds() {
  local missing=() dep
  for dep in "$@"; do command -v "${dep}" >/dev/null 2>&1 || missing+=("${dep}"); done
  (( ${#missing[@]} == 0 )) || die "Missing required command(s): ${missing[*]}"
}

# --- validation ------------------------------------------------------------

validate_ticket() {
  local ticket="${1:-}" pat
  [[ -n "${ticket}" ]] || die "Missing TICKET"
  pat="$(cfg_ticket_pattern)"
  [[ "${ticket}" =~ ${pat} ]] || die "Invalid ticket '${ticket}' (must match ${pat})"
}

is_valid_type() { case "${1:-}" in feature|fix|refactor) return 0;; *) return 1;; esac; }

# --- branch / path naming --------------------------------------------------

sanitize_branch_description() {
  echo "$*" | tr '/ ' '--' | sed -E 's/[^[:alnum:]_.가-힣-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

assert_ascii_safe_path() {
  local path="$1"
  if printf '%s' "${path}" | LC_ALL=C grep -q '[^ -~]'; then
    die "Filesystem worktree path must be ASCII-safe. Refusing: ${path}"
  fi
}

branch_name_for() { # <type> <ticket> [desc...]
  local type="$1" ticket="$2"; shift 2
  local desc; desc="$(sanitize_branch_description "$@")"
  if [[ -n "${desc}" ]]; then echo "${type}/${ticket}_${desc}"; else echo "${type}/${ticket}"; fi
}

# --- session / compose naming ---------------------------------------------

session_name() { printf '%s%s-%s\n' "$(cfg_session_prefix)" "$1" "$2"; }  # <slot> <kind>

# --- seed: copy gitignored artifacts into a fresh worktree -----------------
# Reads project-level (cfg_seed) then component-level (cfg_comp_seed) entries.
# Copies only when destination is missing, unless overwrite=true. Skips by tag.

apply_seed() { # <comp> <slot> <ticket> <wpath> [skip_tags_csv]
  local comp="$1" slot="$2" ticket="$3" wpath="$4" skip="${5:-}"
  local from to overwrite tag src dst
  { cfg_seed; cfg_comp_seed "${comp}"; } | while IFS=$'\t' read -r from to overwrite tag; do
    [[ -n "${from}" ]] || continue
    if [[ -n "${skip}" && -n "${tag}" && ",${skip}," == *",${tag},"* ]]; then continue; fi
    src="$(render_template "${from}" "${comp}" "${slot}" "${ticket}" "${wpath}")"
    src="${src/#\~/${HOME}}"
    dst="${wpath}/$(render_template "${to}" "${comp}" "${slot}" "${ticket}" "${wpath}")"
    if [[ ! -e "${src}" ]]; then warn "  seed source missing: ${src}"; continue; fi
    if [[ -e "${dst}" && "${overwrite}" != "true" ]]; then continue; fi
    mkdir -p "$(dirname "${dst}")"
    cp -R "${src}" "${dst}"
    success "  seeded ${to}"
  done
}
