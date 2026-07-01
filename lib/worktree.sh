#!/usr/bin/env bash
# worktree.sh — git worktree lifecycle, config-driven.
# Components come from cfg_components; repo/root/branch from config accessors;
# gitignored artifacts are copied by apply_seed; env files by render_env.
# Handles stale-vs-live detection, ascii-path guard, slot release on last removal.

WTM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${WTM_LIB_DIR}/config.sh"
source "${WTM_LIB_DIR}/render.sh"
source "${WTM_LIB_DIR}/state.sh"
source "${WTM_LIB_DIR}/env.sh"
source "${WTM_LIB_DIR}/common.sh"

is_live_worktree_dir() { [[ -f "$1/.git" ]]; }

comp_worktree_path() { # <comp> <type> <ticket>
  printf '%s/%s/%s\n' "$(cfg_comp_worktree_root_abs "$1")" "$2" "$3"
}

find_worktree_path_by_comp() { # <comp> <ticket> [allow_stale]
  local comp="$1" ticket="$2" allow_stale="${3:-false}" root path matches=()
  root="$(cfg_comp_worktree_root_abs "${comp}")"
  [[ -d "${root}" ]] || { echo ""; return 0; }
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if [[ "${allow_stale}" != "true" ]] && ! is_live_worktree_dir "${path}"; then continue; fi
    matches+=("${path}")
  done < <(find "${root}" -maxdepth 2 -mindepth 2 -type d -name "${ticket}" 2>/dev/null | sort)
  (( ${#matches[@]} > 1 )) && die "Multiple ${comp} worktrees for ${ticket}: ${matches[*]}"
  (( ${#matches[@]} == 1 )) && echo "${matches[0]}" || echo ""
}

has_any_worktree() { # <ticket>
  local ticket="$1" comp
  while IFS= read -r comp; do
    [[ -n "$(find_worktree_path_by_comp "${comp}" "${ticket}")" ]] && return 0
  done < <(cfg_components)
  return 1
}

enter_ticket() { # <ticket>
  local ticket="$1" found=false comp path stale
  while IFS= read -r comp; do
    path="$(find_worktree_path_by_comp "${comp}" "${ticket}")"
    [[ -n "${path}" ]] && { found=true; echo "[${comp}] ${path}"; }
  done < <(cfg_components)
  ${found} && return 0
  while IFS= read -r comp; do
    stale="$(find_worktree_path_by_comp "${comp}" "${ticket}" true)"
    [[ -n "${stale}" ]] && die "Only stale ${comp} worktree for ${ticket}: ${stale}. Run: wtm cleanup --force"
  done < <(cfg_components)
  die "No worktrees found for ${ticket}"
}

ensure_repo_git() { # <comp>
  local repo; repo="$(cfg_comp_repo_abs "$1")"
  [[ -d "${repo}" ]] || die "Missing repo directory for $1: ${repo}"
  git -C "${repo}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git repo: ${repo}"
}

ensure_base_ref() { # <repo_dir> <base_branch>
  local repo="$1" base="$2"
  git -C "${repo}" fetch origin "${base}" >/dev/null 2>&1 || true
  if git -C "${repo}" show-ref --verify --quiet "refs/remotes/origin/${base}"; then echo "origin/${base}"; return 0; fi
  if git -C "${repo}" show-ref --verify --quiet "refs/heads/${base}"; then echo "${base}"; return 0; fi
  die "Could not resolve base branch '${base}' in ${repo}"
}

create_one_worktree() { # <comp> <type> <ticket> <desc> <base>
  local comp="$1" type="$2" ticket="$3" desc="$4" base="$5"
  ensure_repo_git "${comp}"
  local repo wpath branch base_ref
  repo="$(cfg_comp_repo_abs "${comp}")"
  wpath="$(comp_worktree_path "${comp}" "${type}" "${ticket}")"
  branch="$(branch_name_for "${type}" "${ticket}" "${desc}")"

  [[ "$(cfg_comp_ascii_only "${comp}")" == "true" ]] && assert_ascii_safe_path "${wpath}"

  if [[ -d "${wpath}" ]]; then
    if is_live_worktree_dir "${wpath}"; then warn "${comp} worktree already exists: ${wpath}"; return 0; fi
    die "Stale ${comp} worktree at ${wpath}. Run: wtm cleanup --force"
  fi
  mkdir -p "$(dirname "${wpath}")"
  if git -C "${repo}" show-ref --verify --quiet "refs/heads/${branch}"; then
    git -C "${repo}" worktree add "${wpath}" "${branch}"
  else
    base_ref="$(ensure_base_ref "${repo}" "${base}")"
    git -C "${repo}" worktree add -b "${branch}" "${wpath}" "${base_ref}"
  fi
  success "Created [${comp}] ${wpath}"
}

run_install() { # <comp> <wpath> <no_install> <slot> <ticket>
  local comp="$1" wpath="$2" no_install="${3:-false}" slot="${4:-0}" ticket="${5:-}"
  local cmd marker; cmd="$(cfg_comp_install "${comp}")"
  [[ -n "${cmd}" ]] || return 0
  marker="$(cfg_comp_install_marker "${comp}")"
  if [[ -n "${marker}" && -e "${wpath}/${marker}" ]]; then return 0; fi
  if [[ "${no_install}" == "true" ]]; then warn "  deps missing in ${wpath}; skipping (--no-install)"; return 0; fi
  cmd="$(render_template "${cmd}" "${comp}" "${slot}" "${ticket}" "${wpath}")"
  warn "  installing deps: ${cmd}"
  if ( cd "${wpath}" && eval "${cmd}" ); then success "  install done"; else warn "  install failed in ${wpath} (continuing)"; fi
  return 0
}

setup_ticket() { # <ticket> <no_install> <skip_seed_tags>
  local ticket="$1" no_install="${2:-false}" skip_seed="${3:-}"
  has_any_worktree "${ticket}" || die "No worktrees found for ${ticket}"
  local slot_info slot state
  if slot_info="$(get_or_assign_slot "${ticket}")"; then
    read -r slot state <<< "${slot_info}"
    info "Slot ${slot} (${state}) for ${ticket}"
  else
    warn "No available slots for ${ticket}; continuing without slot"; slot=""
  fi
  local comp wpath
  while IFS= read -r comp; do
    wpath="$(find_worktree_path_by_comp "${comp}" "${ticket}")"
    [[ -n "${wpath}" ]] || continue
    apply_seed "${comp}" "${slot:-0}" "${ticket}" "${wpath}" "${skip_seed}"
    render_env "${comp}" "${slot:-0}" "${ticket}" "${wpath}"
    run_install "${comp}" "${wpath}" "${no_install}" "${slot:-0}" "${ticket}"
  done < <(cfg_components)
}

create_worktrees() { # <comps_space_sep|all> <type> <ticket> <desc> <base> <no_install> <skip_seed>
  local comps="$1" type="$2" ticket="$3" desc="$4" base="$5" no_install="${6:-false}" skip_seed="${7:-}"
  [[ "${comps}" == "all" ]] && comps="$(cfg_components | tr '\n' ' ')"
  local comp
  for comp in ${comps}; do
    cfg_has_component "${comp}" || die "Unknown component: ${comp}"
    create_one_worktree "${comp}" "${type}" "${ticket}" "${desc}" "${base}"
  done
  setup_ticket "${ticket}" "${no_install}" "${skip_seed}"
}

remove_ticket_worktrees() { # <ticket> <prune_branch>
  local ticket="$1" prune="${2:-false}" comp path repo branch remaining=false
  while IFS= read -r comp; do
    path="$(find_worktree_path_by_comp "${comp}" "${ticket}" true)"
    [[ -n "${path}" ]] || continue
    repo="$(cfg_comp_repo_abs "${comp}")"; branch=""
    if [[ -f "${path}/.git" ]]; then
      branch="$(git -C "${path}" branch --show-current 2>/dev/null || true)"
      git -C "${repo}" worktree remove "${path}" --force || rm -rf "${path}"
      git -C "${repo}" worktree prune >/dev/null 2>&1 || true
    else
      rm -rf "${path}"
    fi
    rmdir "$(dirname "${path}")" 2>/dev/null || true
    success "Removed [${comp}] ${path}"
    if [[ "${prune}" == "true" && -n "${branch}" ]]; then
      git -C "${repo}" branch -d "${branch}" >/dev/null 2>&1 \
        && success "  Deleted branch ${branch}" || warn "  Kept branch ${branch} (not merged)"
    fi
  done < <(cfg_components)
  has_any_worktree "${ticket}" && remaining=true
  ${remaining} || { release_slot "${ticket}"; info "Released slot for ${ticket}"; }
}

cleanup_stale_worktrees() { # <force> <prune_branch>
  local force="${1:-false}" prune="${2:-false}" comp repo root dir ticket stale=()
  while IFS= read -r comp; do
    repo="$(cfg_comp_repo_abs "${comp}")"; root="$(cfg_comp_worktree_root_abs "${comp}")"
    [[ -d "${root}" ]] || continue
    git -C "${repo}" worktree prune >/dev/null 2>&1 || true
    for dir in "${root}"/*/*; do
      [[ -d "${dir}" ]] || continue
      [[ -f "${dir}/.git" ]] || stale+=("${comp}:${dir}")
    done
  done < <(cfg_components)
  if (( ${#stale[@]} == 0 )); then success "No stale worktrees found."; return 0; fi
  if [[ "${force}" != "true" ]]; then
    warn "Stale worktrees:"; printf '  - %s\n' "${stale[@]}"
    echo "Run: wtm cleanup --force"; return 0
  fi
  local entry path
  for entry in "${stale[@]}"; do
    comp="${entry%%:*}"; path="${entry#*:}"; ticket="$(basename "${path}")"
    rm -rf "${path}"; rmdir "$(dirname "${path}")" 2>/dev/null || true
    success "Removed stale [${comp}] ${path}"
    has_any_worktree "${ticket}" || release_slot "${ticket}"
  done
}

# TSV records for the CLI: ticket \t type \t slot \t comp \t state \t branch \t path
worktree_list_records() {
  local comp root dir type ticket slot state branch
  while IFS= read -r comp; do
    root="$(cfg_comp_worktree_root_abs "${comp}")"
    [[ -d "${root}" ]] || continue
    for dir in "${root}"/*/*; do
      [[ -d "${dir}" ]] || continue
      type="$(basename "$(dirname "${dir}")")"; ticket="$(basename "${dir}")"
      slot="$(get_slot_for_ticket "${ticket}" 2>/dev/null || true)"; [[ -n "${slot}" ]] || slot="-"
      if [[ -f "${dir}/.git" ]]; then
        state="LIVE"; branch="$(git -C "${dir}" branch --show-current 2>/dev/null || echo '-')"
      else
        state="STALE"; branch="-"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${ticket}" "${type}" "${slot}" "${comp}" "${state}" "${branch}" "${dir}"
    done
  done < <(cfg_components) | sort -t $'\t' -k1,1 -k2,2 -k4,4
}
