#!/usr/bin/env bash
# init.sh — `wtm init` (scaffold .wtm/config.json) and `wtm doctor` (validate).
# Sourced by bin/wtm after runtime.sh, so cfg_*/color/log helpers are in scope.

# Guess a starter shape from files in a directory.
detect_stack() { # <dir>
  local d="${1:-.}"
  if [[ -f "${d}/package.json" ]] && grep -q '"vite"' "${d}/package.json" 2>/dev/null; then echo vite
  elif [[ -f "${d}/package.json" ]] && grep -q '"next"' "${d}/package.json" 2>/dev/null; then echo next
  elif [[ -f "${d}/build.gradle" || -f "${d}/build.gradle.kts" ]]; then echo spring-gradle
  elif [[ -f "${d}/pom.xml" ]]; then echo spring-maven
  else echo generic; fi
}

# Merge one component (name/repo/stack) into an accumulator components object.
# Base port = 8000 + idx*1000 so auto-detected components never collide at a slot.
_comp_merge() { # <acc-json> <name> <repo> <stack> <idx>  -> echoes new acc json
  local acc="$1" name="$2" repo="$3" stack="$4" idx="$5"
  local pn start extra base=$(( 8000 + idx * 1000 ))
  case "${stack}" in
    vite)          pn=vite; start='pnpm dev --port {port.vite}';            extra='{"install":"pnpm install","installMarker":"node_modules"}' ;;
    next)          pn=http; start='pnpm dev -p {port.http}';                extra='{"install":"pnpm install","installMarker":"node_modules"}' ;;
    spring-gradle) pn=http; start="./gradlew bootRun --args='--server.port={port.http}'"; extra='{}' ;;
    spring-maven)  pn=http; start='./mvnw spring-boot:run -Dspring-boot.run.arguments=--server.port={port.http}'; extra='{}' ;;
    *)             pn=http; start='PORT={port.http} ./run.sh';              extra='{}' ;;
  esac
  jq -n --argjson acc "${acc}" --arg name "${name}" --arg repo "${repo}" \
        --arg pn "${pn}" --argjson pb "${base}" --arg start "${start}" --argjson extra "${extra}" '
    $acc + { ($name): ( { repo:$repo, ports:{ ($pn):$pb }, start:$start,
                          health:("{port."+$pn+"}"), runtime:"managed" } + $extra ) }'
}

wtm_init() {
  local target="${PWD}/.wtm/config.json" force=false a
  for a in "$@"; do [[ "$a" == "--force" ]] && force=true; done
  if [[ -f "${target}" && "${force}" != "true" ]]; then
    die ".wtm/config.json already exists (use: wtm init --force)"
  fi

  local proj comps='{}' idx=0 d found=0
  proj="$(basename "${PWD}")"

  if git -C "${PWD}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Project root is itself a git repo -> single component.
    comps="$(_comp_merge "${comps}" "$(basename "${PWD}")" "." "$(detect_stack "${PWD}")" 0)"
    info "Detected a single git repo at the project root."
    found=1
  else
    # Multi-repo workspace: one component per immediate git sub-repo.
    for d in */; do
      d="${d%/}"
      [[ -e "${d}/.git" ]] || continue
      comps="$(_comp_merge "${comps}" "${d}" "${d}" "$(detect_stack "${d}")" "${idx}")"
      info "  + component '${d}' (stack: $(detect_stack "${d}"), port base $(( 8000 + idx * 1000 )))"
      idx=$(( idx + 1 )); found=$(( found + 1 ))
    done
    if (( found == 0 )); then
      comps="$(_comp_merge "${comps}" "app" "." generic 0)"
      warn "No git repos found here or in subdirectories — scaffolded a single placeholder 'app'."
      warn "Edit .wtm/config.json: set each component's 'repo' path and 'start' command."
    else
      info "Detected ${found} component repo(s) in subdirectories."
    fi
  fi

  mkdir -p "${PWD}/.wtm"
  jq -n --arg proj "${proj}" --argjson comps "${comps}" '
    { project:$proj, baseBranch:"main", maxSlots:5,
      ticketPattern:"^[A-Za-z0-9][A-Za-z0-9._-]*$", sessionPrefix:($proj+"-slot"),
      components:$comps }' > "${target}"
  success "Created ${target}"
  info "Next: review .wtm/config.json (start commands, env/seed if needed), then: wtm doctor && wtm up TICKET"
}

wtm_doctor() {
  load_config || die "No .wtm/config.json found (run: wtm init)"
  local errs=0 warns=0
  err(){ echo -e "${RED}  x $*${NC}"; errs=$((errs + 1)); }
  wrn(){ echo -e "${YELLOW}  ! $*${NC}"; warns=$((warns + 1)); }
  okk(){ echo -e "${GREEN}  ok $*${NC}"; }
  info "Config: ${WTM_CONFIG}"

  local proj; proj="$(cfg_project)"
  if [[ -z "${proj}" || "${proj}" == "null" ]]; then err "missing 'project'"; else okk "project: ${proj}"; fi

  local pat; pat="$(cfg_ticket_pattern)"
  if ! printf 'TEST-1' | grep -qE "${pat}" 2>/dev/null; then wrn "ticketPattern may be too strict: ${pat}"; fi

  local comps c; comps="$(cfg_components)"
  if [[ -z "${comps}" ]]; then err "no components defined"; fi
  while IFS= read -r c; do
    [[ -n "${c}" ]] || continue
    local repo; repo="$(cfg_comp_repo_abs "${c}")"
    if [[ -d "${repo}" ]]; then
      if [[ -e "${repo}/.git" ]]; then
        if [[ "$(git -C "${repo}" rev-list -n1 --all 2>/dev/null)" ]]; then okk "[${c}] repo ${repo}"
        else wrn "[${c}] repo has no commits yet — 'wtm up' needs a commit on '$(cfg_base_branch)'"; fi
      else
        wrn "[${c}] repo is not a git repo — worktree ops will fail"
      fi
    else
      wrn "[${c}] repo path not found: ${repo}"
    fi
    local refs r
    refs="$( { cfg_comp_start "${c}"; cfg_comp "${c}" '.env.set // {} | to_entries[]?.value'; } \
             | grep -oE '\{peer\.[A-Za-z0-9_-]+' 2>/dev/null | sed 's/{peer\.//' | sort -u || true )"
    for r in ${refs}; do
      if ! cfg_has_component "${r}"; then err "[${c}] references unknown peer component '${r}'"; fi
    done
    if [[ "$(cfg_comp_runtime "${c}")" == "managed" && -z "$(cfg_comp_start "${c}")" ]]; then
      wrn "[${c}] runtime=managed but no start command"
    fi
  done <<< "${comps}"

  local t
  for t in git jq tmux docker lsof; do
    if command -v "${t}" >/dev/null 2>&1; then okk "tool: ${t}"; else wrn "missing tool: ${t} (needed for run/stop)"; fi
  done

  echo
  if (( errs > 0 )); then die "doctor: ${errs} error(s), ${warns} warning(s)"; fi
  success "doctor: OK (${warns} warning(s))"
}
