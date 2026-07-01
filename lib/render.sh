#!/usr/bin/env bash
# render.sh — template renderer for command/env strings in .wtm/config.json
#
# Tokens (all wrapped in {curly}):
#   {slot}                    -> slot number
#   {ticket}                  -> ticket id
#   {path}                    -> worktree path of the current component
#   {repoMain}                -> absolute main repo dir of the current component
#   {sessionPrefix}           -> config sessionPrefix
#   {port.NAME}               -> current component's ports.NAME + slot
#   {peer.COMP.port.NAME}     -> component COMP's ports.NAME + slot (cross reference)
#   {shellenv.NAME}           -> value of $NAME from the host shell (secrets/paths, not stored in config)
#   {home}                    -> $HOME
#
# Requires config.sh to be sourced (cfg_*, WTM_* in scope).

# Resolve a single bare token (no braces) to its value; empty if unknown.
resolve_token() { # <token> <comp> <slot> <ticket> <wpath>
  local token="$1" comp="$2" slot="$3" ticket="$4" wpath="$5"
  case "${token}" in
    slot)          printf '%s' "${slot}" ;;
    ticket)        printf '%s' "${ticket}" ;;
    path)          printf '%s' "${wpath}" ;;
    repoMain)      printf '%s' "$(cfg_comp_repo_abs "${comp}")" ;;
    sessionPrefix) printf '%s' "$(cfg_session_prefix)" ;;
    home)          printf '%s' "${HOME}" ;;
    shellenv.*)    local name="${token#shellenv.}"; printf '%s' "${!name-}" ;;
    port.*)        cfg_port "${comp}" "${token#port.}" "${slot}" | tr -d '\n' ;;
    peer.*)
      # peer.COMP.port.NAME
      local rest="${token#peer.}"
      local pcomp="${rest%%.*}"
      local pname="${rest##*.port.}"
      if [[ "${rest}" == *".port."* && -n "${pcomp}" && -n "${pname}" ]]; then
        cfg_port "${pcomp}" "${pname}" "${slot}" | tr -d '\n'
      fi
      ;;
    *) : ;;  # unknown token -> empty
  esac
}

# Render a template string, replacing every {token}.
render_template() { # <template> <comp> <slot> <ticket> <wpath>
  local out="$1" comp="$2" slot="$3" ticket="$4" wpath="$5"
  local token val guard=0
  while [[ "${out}" =~ \{([A-Za-z0-9_.-]+)\} ]]; do
    token="${BASH_REMATCH[1]}"
    val="$(resolve_token "${token}" "${comp}" "${slot}" "${ticket}" "${wpath}")"
    out="${out//\{${token}\}/${val}}"
    (( ++guard > 200 )) && break   # safety against pathological input
  done
  printf '%s' "${out}"
}
