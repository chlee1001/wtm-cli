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

component_template_fields() { # <comp> -> TSV: field template
  local c="$1"
  jq -r --arg c "${c}" '
    [
      [("components." + $c + ".install"), (.components[$c].install // "")],
      [("components." + $c + ".start"), (.components[$c].start // "")],
      [("components." + $c + ".health"), (.components[$c].health // "")],
      [("components." + $c + ".compose.project"), (.components[$c].compose.project // "")]
    ]
    + ((.components[$c].env.set // {}) | to_entries | map([("components." + $c + ".env.set." + .key), (.value // "")]))
    + ((.components[$c].guide // []) | to_entries | map([("components." + $c + ".guide[" + (.key|tostring) + "]"), (.value // "")]))
    | .[]
    | select(.[1] != null and .[1] != "")
    | @tsv
  ' "${WTM_CONFIG}"
}

template_token_diagnostics() { # TSV: severity code component field token message
  local c field template raw token name rest pcomp pname base
  while IFS= read -r c; do
    [[ -n "${c}" ]] || continue
    while IFS=$'\t' read -r field template; do
      [[ -n "${template}" ]] || continue
      while IFS= read -r raw; do
        [[ -n "${raw}" ]] || continue
        token="${raw#\{}"; token="${token%\}}"
        case "${token}" in
          slot|ticket|path|repoMain|sessionPrefix|home) ;;
          shellenv.*)
            name="${token#shellenv.}"
            [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || \
              printf 'error\tinvalid_template_token\t%s\t%s\t%s\t%s\n' "${c}" "${field}" "${token}" "[${c}] ${field} references invalid shellenv token '${token}'"
            ;;
          port.*)
            name="${token#port.}"
            base="$(cfg_port_base "${c}" "${name}")"
            [[ -n "${name}" && -n "${base}" ]] || \
              printf 'error\tinvalid_template_token\t%s\t%s\t%s\t%s\n' "${c}" "${field}" "${token}" "[${c}] ${field} references unknown port '${name}'"
            ;;
          peer.*)
            rest="${token#peer.}"
            if [[ "${rest}" != *".port."* ]]; then
              printf 'error\tinvalid_template_token\t%s\t%s\t%s\t%s\n' "${c}" "${field}" "${token}" "[${c}] ${field} has malformed peer token '${token}'"
              continue
            fi
            pcomp="${rest%%.port.*}"
            pname="${rest#*.port.}"
            if [[ -z "${pcomp}" || -z "${pname}" ]]; then
              printf 'error\tinvalid_template_token\t%s\t%s\t%s\t%s\n' "${c}" "${field}" "${token}" "[${c}] ${field} has malformed peer token '${token}'"
            elif ! cfg_has_component "${pcomp}"; then
              printf 'error\tinvalid_template_token\t%s\t%s\t%s\t%s\n' "${c}" "${field}" "${token}" "[${c}] ${field} references unknown peer component '${pcomp}'"
            else
              base="$(cfg_port_base "${pcomp}" "${pname}")"
              [[ -n "${base}" ]] || \
                printf 'error\tinvalid_template_token\t%s\t%s\t%s\t%s\n' "${c}" "${field}" "${token}" "[${c}] ${field} references unknown peer port '${pcomp}.${pname}'"
            fi
            ;;
          *)
            printf 'error\tinvalid_template_token\t%s\t%s\t%s\t%s\n' "${c}" "${field}" "${token}" "[${c}] ${field} references unknown token '${token}'"
            ;;
        esac
      done < <(grep -oE '\{[^}]+\}' <<< "${template}" || true)
    done < <(component_template_fields "${c}")
  done < <(cfg_components)
}

wtm_doctor_json() {
  local rc=0
  load_config || rc=$?
  case "${rc}" in
    0) ;;
    2) json_error_payload "invalid_config_json" "Invalid JSON in .wtm/config.json"; return 1 ;;
    *) json_error_payload "missing_config" "No .wtm/config.json found (run: wtm init)"; return 1 ;;
  esac

  local errs=0 warns=0 diagnostics='[]' tools='[]'
  add_diag() { # <severity> <code> <message> [component] [field] [token]
    local severity="$1" code="$2" message="$3" component="${4:-}" field="${5:-}" token="${6:-}"
    diagnostics="$(jq -c --arg severity "${severity}" --arg code "${code}" --arg message "${message}" \
      --arg component "${component}" --arg field "${field}" --arg token "${token}" '
      . + [{
        severity:$severity,
        code:$code,
        message:$message,
        component:(if $component == "" then null else $component end),
        field:(if $field == "" then null else $field end),
        token:(if $token == "" then null else $token end)
      }]' <<< "${diagnostics}")"
    [[ "${severity}" == "error" ]] && errs=$((errs + 1)) || warns=$((warns + 1))
  }

  local proj; proj="$(cfg_project)"
  [[ -z "${proj}" || "${proj}" == "null" ]] && add_diag error invalid_config "missing 'project'" "" "project"

  local pat; pat="$(cfg_ticket_pattern)"
  if ! printf 'TEST-1' | grep -qE "${pat}" 2>/dev/null; then
    add_diag warning invalid_config "ticketPattern may be too strict: ${pat}" "" "ticketPattern"
  fi

  local comps c; comps="$(cfg_components)"
  [[ -z "${comps}" ]] && add_diag error invalid_config "no components defined" "" "components"
  while IFS= read -r c; do
    [[ -n "${c}" ]] || continue
    local repo; repo="$(cfg_comp_repo_abs "${c}")"
    if [[ -d "${repo}" ]]; then
      if [[ -e "${repo}/.git" ]]; then
        if [[ -z "$(git -C "${repo}" rev-list -n1 --all 2>/dev/null)" ]]; then
          add_diag warning empty_repo "[${c}] repo has no commits yet — 'wtm up' needs a commit on '$(cfg_base_branch)'" "${c}" "components.${c}.repo"
        fi
      else
        add_diag warning invalid_repo "[${c}] repo is not a git repo — worktree ops will fail" "${c}" "components.${c}.repo"
      fi
    else
      add_diag warning missing_repo "[${c}] repo path not found: ${repo}" "${c}" "components.${c}.repo"
    fi
    if [[ "$(cfg_comp_runtime "${c}")" == "managed" && -z "$(cfg_comp_start "${c}")" ]]; then
      add_diag warning missing_start "[${c}] runtime=managed but no start command" "${c}" "components.${c}.start"
    fi
  done <<< "${comps}"

  local severity code component field token message
  while IFS=$'\t' read -r severity code component field token message; do
    [[ -n "${severity}" ]] || continue
    add_diag "${severity}" "${code}" "${message}" "${component}" "${field}" "${token}"
  done < <(template_token_diagnostics)

  local t found path
  for t in git jq tmux docker lsof; do
    if command -v "${t}" >/dev/null 2>&1; then
      found=true; path="$(command -v "${t}")"
    else
      found=false; path=""
      add_diag warning missing_tool "missing tool: ${t} (needed for run/stop)" "" "tools.${t}"
    fi
    tools="$(jq -c --arg name "${t}" --argjson found "${found}" --arg path "${path}" '. + [{name:$name,found:$found,path:$path}]' <<< "${tools}")"
  done

  jq -n --argjson ok "$([[ ${errs} -eq 0 ]] && echo true || echo false)" \
    --arg command doctor --arg root "${WTM_ROOT}" --arg config "${WTM_CONFIG}" --arg project "${proj}" \
    --argjson errors "${errs}" --argjson warnings "${warns}" --argjson diagnostics "${diagnostics}" --argjson tools "${tools}" '
    {
      schemaVersion:1,
      ok:$ok,
      command:$command,
      projectRoot:$root,
      configPath:$config,
      data:{project:$project, errorCount:$errors, warningCount:$warnings, diagnostics:$diagnostics, tools:$tools},
      warnings:($diagnostics | map(select(.severity == "warning"))),
      errors:($diagnostics | map(select(.severity == "error")))
    }'
  (( errs == 0 ))
}

wtm_doctor() {
  if [[ "${JSON_OUTPUT:-false}" == "true" ]]; then wtm_doctor_json; return $?; fi
  local rc=0
  load_config || rc=$?
  case "${rc}" in
    0) ;;
    2) die_code "invalid_config_json" "Invalid JSON in .wtm/config.json" ;;
    *) die_code "missing_config" "No .wtm/config.json found (run: wtm init)" ;;
  esac
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

  local severity code component field token message
  while IFS=$'\t' read -r severity code component field token message; do
    [[ -n "${severity}" ]] || continue
    if [[ "${severity}" == "error" ]]; then err "${message}"; else wrn "${message}"; fi
  done < <(template_token_diagnostics)

  local t
  for t in git jq tmux docker lsof; do
    if command -v "${t}" >/dev/null 2>&1; then okk "tool: ${t}"; else wrn "missing tool: ${t} (needed for run/stop)"; fi
  done

  echo
  if (( errs > 0 )); then die "doctor: ${errs} error(s), ${warns} warning(s)"; fi
  success "doctor: OK (${warns} warning(s))"
}
