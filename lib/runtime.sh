#!/usr/bin/env bash
# runtime.sh — tmux/docker process orchestration, config-driven.
# Each managed component gets a tmux session ({prefix}{slot}-{comp}); start/compose/health
# come from config templates; preflight iterates managed components.
# Port state machine: RUNNING / STARTING / ZOMBIE / ORPHAN / STOPPED.
#
# Requires worktree.sh (which pulls config/render/state/env/common).

WTM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${WTM_LIB_DIR}/worktree.sh"

STARTUP_GRACE_SECONDS="${WTM_STARTUP_GRACE:-180}"

# --- pure seams (unit-testable without tmux/docker) ------------------------

session_for() { session_name "$1" "$2"; }   # <slot> <comp>

# List "portname resolvedport" lines for a component at a slot.
comp_ports() { # <comp> <slot>
  local comp="$1" slot="$2" name
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    printf '%s %s\n' "${name}" "$(cfg_port "${comp}" "${name}" "${slot}")"
  done < <(cfg_comp "${comp}" '.ports // {} | keys[]')
}

is_managed() { [[ "$(cfg_comp_runtime "$1")" == "managed" ]]; }

render_start_cmd() { render_template "$(cfg_comp_start "$1")" "$1" "$2" "$3" "$4"; }

# --- port helpers ----------------------------------------------------------

check_port_available() { # <port> <label>
  local port="$1" label="${2:-port $1}" pids
  pids=$(lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)
  if [[ -n "${pids}" ]]; then
    warn "${label} (port ${port}) already in use"
    ps -p ${pids} -o pid=,command= 2>/dev/null | head -3 | sed 's/^/  /'
    return 1
  fi
  return 0
}

kill_port_listeners() { # <port>
  local port="$1" pids
  pids=$(lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)
  [[ -n "${pids}" ]] || return 0
  kill ${pids} 2>/dev/null || true; sleep 1
  pids=$(lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)
  [[ -n "${pids}" ]] && kill -9 ${pids} 2>/dev/null || true
}

# Preflight: for each managed component with a worktree that is not already
# running, ensure its ports are free.
preflight_slot() { # <slot> <ticket>
  local slot="$1" ticket="$2" comp failed=false wpath name port
  while IFS= read -r comp; do
    is_managed "${comp}" || continue
    wpath="$(find_worktree_path_by_comp "${comp}" "${ticket}")"; [[ -n "${wpath}" ]] || continue
    tmux has-session -t "$(session_for "${slot}" "${comp}")" 2>/dev/null && continue
    while read -r name port; do
      [[ -n "${port}" ]] || continue
      check_port_available "${port}" "${comp}:${name}" || failed=true
    done < <(comp_ports "${comp}" "${slot}")
  done < <(cfg_components)
  ${failed} && { warn "Hint: stop slot ${slot} or free the ports first"; return 1; }
  return 0
}

# --- docker compose (optional per component) -------------------------------

compose_file_abs() { # <comp>
  local f; f="$(cfg_comp "$1" '.compose.file // empty')"
  [[ -n "${f}" ]] && printf '%s/%s\n' "$(cfg_comp_repo_abs "$1")" "${f}"
  return 0
}
compose_project() { render_template "$(cfg_comp "$1" '.compose.project // empty')" "$1" "$2" "$3" ""; }

compose_up() { # <comp> <slot> <ticket>
  local file proj; file="$(compose_file_abs "$1")"; [[ -n "${file}" && -f "${file}" ]] || return 0
  proj="$(compose_project "$1" "$2" "$3")"
  if ( cd "$(cfg_comp_repo_abs "$1")" && docker compose -p "${proj}" -f "${file}" up -d >/dev/null ); then
    success "  compose up: ${proj}"
  else
    warn "  compose up failed: ${proj} (stderr above; continuing)"
  fi
  return 0
}
compose_down() { # <comp> <slot> <ticket>
  local file proj; file="$(compose_file_abs "$1")"; [[ -n "${file}" ]] || return 0
  proj="$(compose_project "$1" "$2" "$3")"
  if docker compose -p "${proj}" -f "${file}" down >/dev/null 2>&1; then success "  compose down: ${proj}"; fi
  return 0
}

# --- start / stop ----------------------------------------------------------

start_component() { # <comp> <slot> <ticket> <wpath>
  local comp="$1" slot="$2" ticket="$3" wpath="$4" session cmd
  session="$(session_for "${slot}" "${comp}")"
  if tmux has-session -t "${session}" 2>/dev/null; then warn "  ${session} already running"; return 0; fi
  cmd="$(render_start_cmd "${comp}" "${slot}" "${ticket}" "${wpath}")"
  [[ -n "${cmd}" ]] || return 0
  tmux new-session -d -s "${session}" "cd '${wpath}' && ${cmd}"
  success "  Started ${session}"
}

stop_slot() { # <slot> <ticket> [force]
  local slot="$1" ticket="${2:-}" force="${3:-false}" comp session
  info "Stopping slot ${slot}..."
  while IFS= read -r comp; do
    session="$(session_for "${slot}" "${comp}")"
    if tmux has-session -t "${session}" 2>/dev/null; then
      tmux kill-session -t "${session}"; success "  Killed ${session}"
    fi
    compose_down "${comp}" "${slot}" "${ticket}"
    if [[ "${force}" == "true" ]]; then
      local name port
      while read -r name port; do [[ -n "${port}" ]] && kill_port_listeners "${port}"; done < <(comp_ports "${comp}" "${slot}")
    fi
  done < <(cfg_components)
  success "Slot ${slot} stopped."
}

# --- ticket-level operations (called by bin/wtm) ---------------------------

run_ticket() { # <ticket> <no_install>
  local ticket="$1" no_install="${2:-false}" slot_info slot state comp wpath
  slot_info="$(get_or_assign_slot "${ticket}")" || die_code "slot_exhausted" "All slots are in use"
  read -r slot state <<< "${slot_info}"
  preflight_slot "${slot}" "${ticket}" || die_code "port_conflict" "Port conflict for slot ${slot}"

  while IFS= read -r comp; do
    wpath="$(find_worktree_path_by_comp "${comp}" "${ticket}")"; [[ -n "${wpath}" ]] || continue
    render_env "${comp}" "${slot}" "${ticket}" "${wpath}"
    run_install "${comp}" "${wpath}" "${no_install}" "${slot}" "${ticket}"
    compose_up "${comp}" "${slot}" "${ticket}"
    if is_managed "${comp}"; then
      start_component "${comp}" "${slot}" "${ticket}" "${wpath}"
    else
      info "  [${comp}] runtime=guide — manual steps:"
      cfg_comp "${comp}" '.guide[]? // empty' | while IFS= read -r line; do
        echo "    $(render_template "${line}" "${comp}" "${slot}" "${ticket}" "${wpath}")"
      done
    fi
  done < <(cfg_components)

  sleep 3
  local ok=true
  while IFS= read -r comp; do
    is_managed "${comp}" || continue
    wpath="$(find_worktree_path_by_comp "${comp}" "${ticket}")"; [[ -n "${wpath}" ]] || continue
    tmux has-session -t "$(session_for "${slot}" "${comp}")" 2>/dev/null || { warn "  [FAIL] ${comp} died immediately"; ok=false; }
  done < <(cfg_components)
  ${ok} || return 1
  success "${ticket} started on slot ${slot}"
}

stop_ticket() { # <ticket>
  local ticket="$1" slot; slot="$(get_slot_for_ticket "${ticket}")"
  [[ -n "${slot}" ]] || { warn "No slot for ${ticket}; nothing to stop"; return 0; }
  stop_slot "${slot}" "${ticket}" true
}

logs_ticket() { # <ticket> <comp> <lines>
  local ticket="$1" comp="${2:-}" lines="${3:-120}" slot session printed=false
  slot="$(get_slot_for_ticket "${ticket}")"; [[ -n "${slot}" ]] || die "No slot for ${ticket}"
  while IFS= read -r c; do
    [[ -n "${comp}" && "${comp}" != "${c}" ]] && continue
    session="$(session_for "${slot}" "${c}")"
    if tmux has-session -t "${session}" 2>/dev/null; then
      echo "===== ${session} ====="; tmux capture-pane -p -S -"${lines}" -t "${session}" || true; printed=true
    fi
  done < <(cfg_components)
  ${printed} || die "No running session for ${ticket}"
}

tmux_session_age() { # <session>
  local created; created=$(tmux display-message -p -t "$1" "#{session_created}" 2>/dev/null || true)
  [[ "${created}" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
  echo $(( $(date +%s) - created ))
}

# Component state: RUNNING / STARTING / ZOMBIE / ORPHAN / STOPPED
component_status() { # <comp> <slot>
  local comp="$1" slot="$2" session has_tmux=false port_up=false hport age
  is_managed "${comp}" || { echo "GUIDE"; return 0; }
  session="$(session_for "${slot}" "${comp}")"
  tmux has-session -t "${session}" 2>/dev/null && has_tmux=true
  hport="$(render_template "$(cfg_comp_health "${comp}")" "${comp}" "${slot}" "" "")"
  if [[ -n "${hport}" ]] && lsof -i ":${hport}" -sTCP:LISTEN -t >/dev/null 2>&1; then port_up=true; fi
  if ${has_tmux}; then
    if ${port_up}; then echo "RUNNING"
    else
      age="$(tmux_session_age "${session}")"
      if [[ -n "${age}" && ${age} -lt ${STARTUP_GRACE_SECONDS} ]]; then echo "STARTING"; else echo "ZOMBIE"; fi
    fi
  else
    ${port_up} && echo "ORPHAN" || echo "STOPPED"
  fi
}
