# wtm — worktree + runtime manager

**English** · [한국어](README.ko.md)

Turn one ticket into an isolated, runnable full‑stack environment across any number of
repos — with collision‑free ports, per‑slot databases, tmux process management, and
health checks. Everything project‑specific lives in a single `.wtm/config.json`, so the
same engine works on any multi‑repo project.

```console
$ wtm up --target all IHWP-1299 payment-fix
Created [server] .../work-plus-server.worktrees/feature/IHWP-1299
Created [web]    .../work-plus-web-v2.worktrees/feature/IHWP-1299
Slot 2 (assigned) for IHWP-1299
  Started wp-slot2-server   # :9082  (+ mysql :3308, valkey :6381)
  Started wp-slot2-web      # :4202, VITE_API_URL -> :9082
```

## Why

A feature that spans several repos (backend + web + app) needs those repos branched
*together* and running *together*. Do that for a handful of tickets at once and you drown
in port collisions, cross‑contaminated databases, dependency reinstalls, and orphaned
processes. `wtm` gives each ticket a **slot** — a small integer that every port derives
from (`base + slot`) — so up to N tickets run in parallel, each fully isolated and
reproducible. `FOO-1` on slot 1 is *always* the same ports.

## Features

- **Multi‑repo, config‑driven** — declare each component (repo) once; no code changes to adopt.
- **Slot isolation** — deterministic, collision‑free ports for backend, DB, cache, frontend.
- **Full lifecycle** — create worktrees, install deps, hydrate env, run (tmux), logs, status, stop, delete.
- **Per‑slot infra** — optional Docker Compose (DB/cache) isolated per ticket.
- **Env that follows the slot** — port‑dependent keys (API URLs, OAuth redirects) rewritten per slot.
- **Seeding** — copy gitignored artifacts (`.env`, `.claude`, certs) into fresh worktrees.
- **State machine** — `RUNNING / STARTING / ZOMBIE / ORPHAN / STOPPED` so leaked processes are visible.
- **Zero‑friction onboarding** — `wtm init` auto‑detects your repos; `wtm doctor` validates the config.

## Install

Requires `bash`, `git`, `jq` (runtime also uses `tmux`, `docker`, `lsof`).

```bash
git clone https://github.com/chlee1001/wtm-cli ~/tools/wtm

# put `wtm` on your PATH (create the dir first — it may not exist yet)
mkdir -p ~/.local/bin
ln -sf ~/tools/wtm/bin/wtm ~/.local/bin/wtm

# if ~/.local/bin isn't on your PATH yet, add it (zsh) and reload the shell:
#   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && exec zsh

wtm help
```

Any directory on your `$PATH` works — `~/.local/bin` is just a common choice.

## Quickstart

```bash
cd my-app                 # a workspace with component repos as subfolders (api/, web/, ...)
wtm init                  # scans subfolders for git repos, scaffolds .wtm/config.json
$EDITOR .wtm/config.json  # set each component's start command (+ env/seed if needed)
wtm doctor                # validate config, repos, tooling
wtm up --target all FOO-1 my-feature
wtm status                # FOO-1 -> RUNNING on its slot
wtm delete FOO-1 --prune-branch
```

The engine finds `.wtm/config.json` by walking up from the current directory (git‑style),
so `wtm` works from any subfolder.

## Configuration

A minimal two‑component example (`web` talks to `api` on the same slot):

```jsonc
{
  "project": "my-app",
  "baseBranch": "main",
  "maxSlots": 5,                 // slot 0 is the reserved baseline; tickets get 1..N-1
  "sessionPrefix": "myapp-slot",
  "components": {
    "api": {
      "repo": "api",
      "ports": { "http": 8080 },
      "start": "./gradlew bootRun --args='--server.port={port.http}'",
      "compose": { "file": "docker-compose.local.yml", "project": "{sessionPrefix}{slot}" },
      "health": "{port.http}"
    },
    "web": {
      "repo": "web",
      "ports": { "vite": 4200 },
      "install": "pnpm install", "installMarker": "node_modules",
      "start": "pnpm dev --port {port.vite}",
      "env": {
        "file": ".env.local",
        "set": { "VITE_API_URL": "http://localhost:{peer.api.port.http}/api" }
      },
      "seed": [ { "from": "{repoMain}/.claude", "to": ".claude", "tag": "agent" } ]
    }
  }
}
```

See [`schema/config.schema.json`](schema/config.schema.json) for the full schema,
[`presets/`](presets) for stack starters (vite / spring‑gradle / generic), and
[`examples/work-plus.config.json`](examples/work-plus.config.json) for a complete real config.

### Template tokens

Usable in `start`, `install`, `env`, `compose`, `seed`, `health`:

| token | meaning |
|---|---|
| `{slot}` | assigned slot number |
| `{ticket}` | ticket id |
| `{path}` | worktree path of the current component |
| `{repoMain}` | absolute main repo dir of the current component |
| `{sessionPrefix}` | config `sessionPrefix` |
| `{port.NAME}` | current component's `ports.NAME` + slot |
| `{peer.COMP.port.NAME}` | component `COMP`'s `ports.NAME` + slot (cross‑reference) |
| `{shellenv.NAME}` | value of `$NAME` from the host shell (secrets, not stored in config) |
| `{home}` | `$HOME` |

## Commands

| command | what it does |
|---|---|
| `wtm init` | scaffold `.wtm/config.json` (auto‑detects sub‑repos and their stacks) |
| `wtm doctor` | validate config, repo/git state, peer refs, tooling |
| `wtm up [--target C] [--type T] TICKET [desc]` | create (or reuse) worktrees, then run |
| `wtm create … TICKET` | create worktrees only (seed + env + install) |
| `wtm run TICKET` | run the stack for a ticket |
| `wtm stop TICKET` / `wtm delete TICKET [--prune-branch]` | stop / stop + remove |
| `wtm logs TICKET [component] [--lines N]` | tail tmux logs |
| `wtm status [TICKET]` | slot / component state table |
| `wtm slots [--max N]` | slot → ports table, or change the slot count |
| `wtm list [--compact|--wide]` | list worktrees |
| `wtm enter TICKET` / `wtm cleanup [--force]` | print paths / prune stale worktrees |

`--target` takes a component name, a comma‑list, or `all`. `--type` is `feature`, `fix`, or `refactor`.

## How slots work

`slot 0` is a shared baseline (never assigned to a ticket). Tickets get `1 .. maxSlots-1`.
Every port is `base + slot`, so components never collide across tickets:

```
slot 1 → api 8081 / web 4201        slot 2 → api 8082 / web 4202
```

Adjust the count anytime with `wtm slots --max N` (refuses to shrink below an in‑use slot).

## Testing

```bash
for t in tests/*.sh; do bash "$t"; done
```

11 suites, 122 checks — including real `git worktree` and `tmux` end‑to‑end runs.

## Layout

```
bin/wtm                 entry point (arg parsing, dispatch, presenters)
lib/config.sh           .wtm/config.json discovery + accessors
lib/render.sh           template renderer
lib/state.sh            slot ledger (locked)
lib/{common,worktree,runtime,env,init}.sh   lifecycle, tmux/docker, env, init/doctor
presets/ · schema/ · examples/ · tests/
```

## Limitations

- **Runtimes that can't be slot‑isolated.** Some processes bind a fixed global port
  regardless of slot — e.g. a React Native **Metro bundler is fixed at `:8081`**. For such
  a component, set `"runtime": "guide"`: `wtm` creates and seeds the worktree, then prints
  the component's `guide` steps for you to run manually instead of managing the process.
  It shows as `GUIDE` in `wtm status` (never `RUNNING`), its port is **not** slot‑derived,
  so only one such component can run at a time. (See the `app` component in
  [`examples/work-plus.config.json`](examples/work-plus.config.json).)
- **Slot 0 is reserved** as the shared baseline, so with `maxSlots: N` you get `N-1`
  concurrent ticket slots (default 5 → 4 tickets).
- **Local, single‑machine.** `wtm` drives local `git`, `tmux`, and `docker`; there is no
  remote/multi‑host mode.

## License

[MIT](LICENSE)
