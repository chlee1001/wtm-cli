#!/usr/bin/env bash
# env.sh — declarative env-file hydration.
#
# git worktrees carry tracked files only, so a component's env file (e.g. .env.local,
# usually gitignored) must be seeded from a template and have every PORT-DEPENDENT key
# rewritten to follow the slot. Unlike a plain seed copy, env keys need value rewriting.
#
# For each key in components.<c>.env.set:
#   - if the key exists in the target file  -> replace in place (position & comments kept)
#   - if absent                             -> append
# Non-port keys (titles, client ids, base urls) are copied verbatim from the template.
#
# Requires config.sh + render.sh sourced.

# Replace or append KEY=VALUE in an env file, preserving line position when present.
# Key/value are passed via ENVIRON (not awk -v) so no escape processing happens —
# values containing backslashes, &, or slashes are written verbatim.
env_upsert() { # <file> <key> <value>
  local file="$1" key="$2" value="$3"
  if WTM_UPSERT_K="${key}" awk 'BEGIN{k=ENVIRON["WTM_UPSERT_K"]} index($0,k"=")==1{f=1} END{exit !f}' "${file}" 2>/dev/null; then
    WTM_UPSERT_K="${key}" WTM_UPSERT_V="${value}" awk '
      BEGIN{ k=ENVIRON["WTM_UPSERT_K"]; v=ENVIRON["WTM_UPSERT_V"] }
      { if (index($0, k"=") == 1) print k"="v; else print }
    ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

# True if the target env file is missing any required key.
env_incomplete() { # <file> <comp>
  local file="$1" comp="$2" k
  [[ -f "${file}" ]] || return 0
  while IFS= read -r k; do
    [[ -n "${k}" ]] || continue
    grep -q "^${k}=" "${file}" || return 0
  done < <(cfg_comp_env_required "${comp}")
  return 1
}

# Hydrate a component's env file for a given slot.
render_env() { # <comp> <slot> <ticket> <wpath>
  local comp="$1" slot="$2" ticket="$3" wpath="$4"

  local ef; ef="$(cfg_comp_env_file "${comp}")"
  [[ -n "${ef}" ]] || return 0                       # no env block: nothing to do
  local target="${wpath}/${ef}"

  # 1) ensure the file exists and is complete, else (re)seed from the rendered template
  if env_incomplete "${target}" "${comp}"; then
    local tmpl src
    tmpl="$(cfg_comp_env_template "${comp}")"
    if [[ -n "${tmpl}" ]]; then
      src="$(render_template "${tmpl}" "${comp}" "${slot}" "${ticket}" "${wpath}")"
      if [[ -f "${src}" ]]; then
        mkdir -p "$(dirname "${target}")"
        cp "${src}" "${target}"
      fi
    fi
  fi
  [[ -f "${target}" ]] || { echo "Error: no env file and no template for ${comp}: ${target}" >&2; return 1; }

  # 2) rewrite every declared port-dependent key so it follows the slot
  local key val
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    val="$(render_template "$(cfg_comp_env_set_val "${comp}" "${key}")" "${comp}" "${slot}" "${ticket}" "${wpath}")"
    env_upsert "${target}" "${key}" "${val}"
  done < <(cfg_comp_env_set_keys "${comp}")
}
