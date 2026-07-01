# wtm — 워크트리 + 런타임 매니저

한국어 · [English](README.md)

티켓 하나를 여러 레포에 걸친 격리된 풀스택 실행 환경으로 만들어 준다. 충돌 없는 포트,
슬롯별 데이터베이스, tmux 프로세스 관리, 헬스체크까지 붙는다. 프로젝트마다 다른 부분은
`.wtm/config.json` 한 파일에 모여 있어서 어떤 멀티레포 프로젝트에서든 같은 엔진이 돈다.

```console
$ wtm up --target all IHWP-1299 payment-fix
Created [server] .../work-plus-server.worktrees/feature/IHWP-1299
Created [web]    .../work-plus-web-v2.worktrees/feature/IHWP-1299
Slot 2 (assigned) for IHWP-1299
  Started wp-slot2-server   # :9082  (+ mysql :3308, valkey :6381)
  Started wp-slot2-web      # :4202, VITE_API_URL -> :9082
```

## 왜 필요한가

백엔드·웹·앱처럼 여러 레포에 걸친 기능은 그 레포들을 함께 브랜칭하고 함께 띄워야 한다.
이걸 여러 티켓에서 동시에 하다 보면 포트 충돌, 데이터베이스 교차 오염, 의존성 재설치,
떠도는 프로세스에 금방 파묻힌다. wtm은 티켓마다 **슬롯**(작은 정수)을 배정하고 모든 포트를
`base + slot`으로 파생한다. 그래서 티켓 N개가 각자 격리된 채 동시에 돌고 재현도 된다.
slot 1에 배정된 `FOO-1`은 언제나 같은 포트다.

## 기능

- 멀티레포 · 설정 기반 — 컴포넌트(레포)를 한 번 선언하면 된다. 도입에 코드 수정이 없다.
- 슬롯 격리 — 백엔드·DB·캐시·프론트가 결정적이고 충돌 없는 포트를 받는다.
- 전체 생명주기 — 워크트리 생성, 의존성 설치, env 주입, 실행(tmux), 로그, 상태, 정지, 삭제.
- 슬롯별 인프라 — 티켓마다 격리된 Docker Compose(DB·캐시)를 선택적으로 띄운다.
- 슬롯을 따라가는 env — API URL·OAuth 리다이렉트처럼 포트가 박힌 키를 슬롯에 맞춰 다시 쓴다.
- 시딩 — gitignore된 파일(`.env`, `.claude`, 인증서)을 새 워크트리로 복사한다.
- 상태 머신 — `RUNNING / STARTING / ZOMBIE / ORPHAN / STOPPED`. 새는 프로세스가 눈에 보인다.
- 낮은 진입 비용 — `wtm init`이 레포를 자동 감지하고, `wtm doctor`가 설정을 검증한다.

## 설치

`bash`, `git`, `jq`가 필요하다(런타임에는 `tmux`, `docker`, `lsof`도 쓴다).

```bash
git clone https://github.com/chlee1001/wtm-cli ~/tools/wtm

# `wtm`을 PATH에 올린다 (디렉토리가 없을 수 있으니 먼저 만든다)
mkdir -p ~/.local/bin
ln -sf ~/tools/wtm/bin/wtm ~/.local/bin/wtm

# ~/.local/bin 이 아직 PATH에 없으면 추가하고 셸을 다시 로드한다 (zsh):
#   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && exec zsh

wtm help
```

PATH에 있는 디렉토리면 어디든 된다 — `~/.local/bin`은 흔한 선택일 뿐이다.

## 빠른 시작

```bash
cd my-app                 # 컴포넌트 레포가 하위 폴더로 있는 워크스페이스 (api/, web/, ...)
wtm init                  # 하위 폴더의 git 레포를 스캔해 .wtm/config.json 생성
$EDITOR .wtm/config.json  # 컴포넌트별 start 명령 지정 (필요하면 env/seed도)
wtm doctor                # 설정·레포·툴 점검
wtm up --target all FOO-1 my-feature
wtm status                # FOO-1 이 자기 슬롯에서 RUNNING
wtm delete FOO-1 --prune-branch
```

엔진은 현재 디렉토리에서 위로 올라가며 `.wtm/config.json`을 찾는다(git과 같은 방식). 그래서
하위 어느 폴더에서 실행해도 동작한다.

## 설정

두 컴포넌트 예시(`web`이 같은 슬롯의 `api`를 바라본다):

```jsonc
{
  "project": "my-app",
  "baseBranch": "main",
  "maxSlots": 5,                 // slot 0 은 예약된 baseline, 티켓은 1..N-1 을 받는다
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

전체 스키마는 [`schema/config.schema.json`](schema/config.schema.json), 스택별 시작 틀은
[`presets/`](presets)(vite · spring‑gradle · generic), 실제 완성 예시는
[`examples/work-plus.config.json`](examples/work-plus.config.json)에 있다.

### 템플릿 토큰

`start`, `install`, `env`, `compose`, `seed`, `health`에서 쓴다.

| 토큰 | 뜻 |
|---|---|
| `{slot}` | 배정된 슬롯 번호 |
| `{ticket}` | 티켓 ID |
| `{path}` | 현재 컴포넌트의 워크트리 경로 |
| `{repoMain}` | 현재 컴포넌트의 메인 레포 절대경로 |
| `{sessionPrefix}` | 설정의 `sessionPrefix` |
| `{port.NAME}` | 현재 컴포넌트의 `ports.NAME` + slot |
| `{peer.COMP.port.NAME}` | 다른 컴포넌트 `COMP`의 `ports.NAME` + slot (크로스 참조) |
| `{shellenv.NAME}` | 호스트 셸의 `$NAME` 값 (비밀키 등, 설정에 안 박음) |
| `{home}` | `$HOME` |

## 명령

| 명령 | 하는 일 |
|---|---|
| `wtm init` | `.wtm/config.json` 생성 (하위 레포와 스택 자동 감지) |
| `wtm doctor` | 설정·레포/git 상태·peer 참조·툴 점검 |
| `wtm up [--target C] [--type T] TICKET [desc]` | 워크트리 생성(또는 재사용) 후 실행 |
| `wtm create … TICKET` | 워크트리만 생성 (시드 + env + 설치) |
| `wtm run TICKET` | 티켓의 스택 실행 |
| `wtm stop TICKET` / `wtm delete TICKET [--prune-branch]` | 정지 / 정지 + 제거 |
| `wtm logs TICKET [component] [--lines N]` | tmux 로그 출력 |
| `wtm status [TICKET]` | 슬롯·컴포넌트 상태 표 |
| `wtm slots [--max N]` | 슬롯→포트 표, 또는 슬롯 개수 변경 |
| `wtm list [--compact|--wide]` | 워크트리 목록 |
| `wtm enter TICKET` / `wtm cleanup [--force]` | 경로 출력 / stale 워크트리 정리 |

`--target`은 컴포넌트 이름, 쉼표 목록, 또는 `all`을 받는다. `--type`은 `feature`·`fix`·`refactor`.

GUI/도구 연동용 machine-readable 출력은 다음 명령에서 `--json`으로 사용할 수 있다.

```bash
wtm doctor --json
wtm status --json [TICKET]
wtm list --json
wtm slots --json
```

JSON 출력은 추가 기능이다. 기본 human-readable 출력은 그대로 유지한다. 오류 payload에는
`missing_config`, `invalid_config_json`, `unknown_component`, `slot_exhausted`,
`invalid_template_token` 같은 안정적인 machine code가 포함된다.

## 슬롯 동작 방식

`slot 0`은 공유 baseline이고 티켓에 배정하지 않는다. 티켓은 `1 .. maxSlots-1`을 받는다.
모든 포트가 `base + slot`이라 티켓끼리 컴포넌트가 겹치지 않는다.

```
slot 1 → api 8081 / web 4201        slot 2 → api 8082 / web 4202
```

개수는 `wtm slots --max N`으로 언제든 바꾼다(사용 중인 슬롯 아래로는 줄이지 않는다).

## 테스트

```bash
for t in tests/*.sh; do bash "$t"; done
```

13개 스크립트, 151개 활성 검사. JSON 계약 회귀 테스트와 실제 `git worktree`/`tmux` e2e를 포함한다.

## 구조

```
bin/wtm                 진입점 (인자 파싱, 디스패치, 출력)
lib/config.sh           .wtm/config.json 탐색 + 접근자
lib/render.sh           템플릿 렌더러
lib/state.sh            슬롯 원장 (락)
lib/{common,worktree,runtime,env,init}.sh   생명주기, tmux/docker, env, init/doctor
presets/ · schema/ · examples/ · tests/
```

## 한계

- **슬롯 격리가 불가능한 런타임.** 슬롯과 무관하게 고정된 전역 포트를 잡는 프로세스가 있다 —
  예를 들어 React Native의 **Metro 번들러는 `:8081`에 고정**된다. 이런 컴포넌트는
  `"runtime": "guide"`로 두면 된다. wtm이 워크트리를 만들고 시드까지 해준 뒤, 프로세스를 직접
  관리하는 대신 컴포넌트의 `guide` 단계를 출력한다. `wtm status`에는 `RUNNING`이 아니라 `GUIDE`로
  표시되고 포트도 슬롯에서 파생되지 않으므로, 이런 컴포넌트는 한 번에 하나만 띄울 수 있다.
  ([`examples/work-plus.config.json`](examples/work-plus.config.json)의 `app` 컴포넌트 참고.)
- **slot 0은 예약**이라 `maxSlots: N`이면 동시 티켓 슬롯은 `N-1`개다(기본 5 → 티켓 4개).
- **로컬·단일 머신.** wtm은 로컬 `git`·`tmux`·`docker`를 다룬다. 원격/멀티 호스트 모드는 없다.

## 라이선스

[MIT](LICENSE)
