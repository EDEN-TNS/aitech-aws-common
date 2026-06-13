# Dist Standard Service — 배포 부트스트랩 시리즈

임의의 Git 저장소 묶음을 클론하고, 필요한 도구(`git` · `gh` · `docker` · `docker compose v2` · `make`)를 자동 설치·검증한 뒤 `docker compose` 스택을 기동하는 범용 부트스트랩 스크립트 2종.

동일한 배포 파이프라인을 **CLI 대화형**과 **REPL 인터랙티브 셸** 두 가지 인터페이스로 제공합니다.

---

## 어떤 스크립트를 쓸까?

|  | [`dist-standard-service.sh`](#dist-standard-servicesh--cli-버전) | [`dist-ss-tui.sh`](#dist-ss-tuish-v30--repl-버전) |
|---|---|---|
| 인터페이스 | CLI 대화형 (번호 메뉴) | REPL 커맨드 셸 (자동완성 + 히스토리) |
| 저장소 지정 | `-I` 플래그 **필수** | `/repo` CRUD 또는 `-I` 사전 지정 |
| 저장소 관리 | 단순 URL 입력 | 추가 / 삭제 / 순서 변경 (최대 8개) |
| 인증 방식 | `gh auth` 전용 | `gh auth` / PAT / 없음 선택 |
| PAT 지원 | ✗ | ✓ (임시 credential, 종료 시 자동 삭제) |
| SSH→HTTPS 변환 | ✗ | ✓ (PAT 모드에서 자동) |
| 커맨드 자동완성 | ✗ | ✓ (`/` 입력 시 메뉴) |
| 커맨드 히스토리 | ✗ | ✓ (↑↓ 방향키) |
| 커서 이동 | ✗ | ✓ (←→ 방향키) |
| 설정 상태 확인 | ✗ | ✓ (`/status`) |
| Bootstrap 상태 추적 | ✗ | ✓ (`BOOTSTRAP_DONE` 플래그) |
| 비대화형 CLI 모드 | `--no-run` 조합 | ✓ (`--cli` 플래그 또는 stdin non-tty) |
| 셸 명령 실행 | Pre-run 커맨드 루프 | `! <cmd>` (언제든) |
| 종료 | Ctrl+C | `/exit` 또는 Ctrl+C×2 (2초 이내) |
| 세션 캐시 | ✗ | ✓ (`/tmp/.dist-ss-tui-<UID>.cache`) |
| 상태 파일 | `.dist-standard.conf` | `.dist-standard.conf` |

---

## 대상 환경

- **OS**: Ubuntu 22.04+ / Debian 12+ (1차 지원), Fedora/RHEL/Rocky/AlmaLinux, Arch, macOS (Homebrew)
- **Shell**: `bash`
- **권한**: 일반 사용자 + `sudo` 가능 (패키지 설치, `systemctl`, `usermod` 등)
- **네트워크**: `github.com`, `cli.github.com`, `raw.githubusercontent.com`, `download.docker.com` 접근 가능

> ⚠️ `sudo ./script.sh` 처럼 root로 직접 실행하지 마세요. `gh` 인증 / `docker` 그룹 / `~/.dist-standard.conf` 등이 root 홈에 묶입니다. 일반 사용자로 실행하면 스크립트가 필요 시점에만 `sudo`를 호출합니다.

---

## 공통 내부 동작

두 스크립트가 동일한 로직을 공유합니다.

### OS 감지 및 패키지 매니저

| OS | 감지 조건 | 패키지 매니저 |
|----|-----------|---------------|
| macOS | `uname -s == Darwin` | Homebrew (`brew`) |
| Debian/Ubuntu | `/etc/os-release` ID_LIKE=debian | `apt-get update && apt-get install -y` |
| Fedora/RHEL/Rocky/AlmaLinux | ID_LIKE=fedora/rhel/centos | `dnf` 또는 `yum` |
| Arch | ID_LIKE=arch | `pacman -S --noconfirm` |

### Docker 설치

배포판 기본 패키지 대신 **Docker 공식 저장소**에서 설치합니다.

| 배포판 | 이유 |
|--------|------|
| Debian/Ubuntu | Ubuntu 기본 repo에 `docker-compose-plugin` 없음 |
| RHEL 계열 | `dnf install docker`는 `podman-docker` 심만 설치 (compose v2 없음) |

- **Debian/Ubuntu**: `/etc/apt/keyrings/docker.gpg` 키링 등록 후 `docker-ce` + `docker-compose-plugin` 설치
- **RHEL 계열**: `podman-docker` 제거 → `docker-ce.repo` 등록 → 설치 (dnf4 `--add-repo` / dnf5 `addrepo` 자동 분기)
- **Arch**: `pacman -S docker docker-compose`
- **macOS**: `brew install --cask docker` 후 Docker.app 자동 실행 대기 (최대 60초)

#### GitHub CLI APT 키링 자동 복구 (Debian/Ubuntu)

`apt-get update` 시 `NO_PUBKEY 23F3D4EA75716059` 또는 `cli.github.com … is not signed` 오류 감지 시 자동 복구를 시도합니다. 복구 실패 시 gh APT 저장소를 비활성화하며 기존 gh 바이너리는 그대로 유지됩니다.

### docker group 처리 (Linux)

```
/etc/group에 사용자 추가 (usermod -aG docker)
  ↓
현재 셸 보조 그룹 확인 (id -nG)
  ├─ 그룹 활성화됨 → docker 직접 호출
  └─ 미활성화 → DAEMON_NEEDS_SG=1
       → 모든 docker/make 호출을 sg docker -c "..." 로 래핑
```

스크립트 완료 후 `finalize_docker_access`에서 서브셸 활성화 메뉴를 제공합니다.

### Makefile 자동 생성

`OPS_DIR/Makefile`이 없고 `docker-compose*.yml` / `compose*.yml`이 발견되면 자동 생성합니다. 기존 Makefile은 절대 덮어쓰지 않습니다.

```makefile
# 생성 규칙
up:      docker compose -f <base> up -d
down:    docker compose -f <base> down
ps:      docker compose -f <base> ps
logs:    docker compose -f <base> logs -f --tail=200
build:   docker compose -f <base> build
clean:   docker compose -f <base> down -v --remove-orphans

# base 외 추가 compose 파일마다
up-<tag>:   docker compose -f <base> -f <extra> up -d
down-<tag>: docker compose -f <base> -f <extra> down
```

- **base 선택**: `docker-compose.yml` / `compose.yml` 중 가장 얕은 경로
- **태그 생성**: 파일명에서 확장자·공통 prefix 제거, 서브디렉터리는 `-` 구분자로 경로 포함
- **스캔 제외 디렉터리**: `.git`, `node_modules`, `vendor`, `dist`, `build`, `.venv`, `__pycache__` (maxdepth 6)

### 실패 시 컨테이너 로그 수집

`make` 타깃 실패 시 비정상 컨테이너 로그 자동 출력 (`dump_unhealthy_logs`).

```
Up + (healthy) 상태 → 스킵
그 외 (unhealthy, Exited, Restarting 등) → docker logs --tail=N 출력
```

tail 줄 수: `dist-standard-service.sh` = 80줄, `dist-ss-tui.sh` = 40줄

### 상태 파일

`<OPS_DIR>/.dist-standard.conf`

```bash
LAST_TARGET='up'
LAST_RUN='2026-06-13T10:30:00Z'
```

다음 실행 시 자동 로드 → 마지막 타깃을 기본값으로 표시합니다. ops 저장소의 `.gitignore`에 추가를 권장합니다.

---

## `dist-standard-service.sh` — CLI 버전

### 인자

| 플래그 | 설명 | 기본값 | 필수 |
|--------|------|--------|------|
| `-I`, `--input <repos>` | 공백 구분 Git URL 목록 (따옴표로 묶거나 다중 인자) | — | ✅ |
| `-w`, `--workspace <dir>` | 클론 대상 디렉터리 | 런타임 메뉴 선택 | ❌ |
| `-o`, `--ops <name>` | Makefile/compose 보유 저장소 이름 | compose 파일 있는 첫 번째 저장소 자동 감지 | ❌ |
| `--no-run` | 설치·클론은 수행, compose 메뉴 스킵 | — | ❌ |
| `-h`, `--help` | 도움말 표시 | — | ❌ |

### 실행 방법

> 스크립트는 **인터랙티브 프롬프트**(워크스페이스 선택, `gh` 계정 메뉴, 타깃 선택)를 사용합니다.
> `curl … | bash` 처럼 stdin을 파이프로 점유하면 `read` 호출이 즉시 EOF로 빠집니다.
> **권장 방식은 프로세스 치환** `bash <(curl …)` 입니다.

#### 방법 1 (권장): 프로세스 치환

```bash
# 최소 — workspace/ops 런타임 자동 처리
bash <(curl -fsSL https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/dist-service/dist-standard-service.sh) \
  -I "https://github.com/acme/svc-a https://github.com/acme/svc-b"

# 전체 옵션 지정
bash <(curl -fsSL https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/dist-service/dist-standard-service.sh) \
  --input "https://github.com/acme/ops https://github.com/acme/api" \
  --workspace ~/work \
  --ops ops

# 설치·클론만, compose 메뉴 스킵
bash <(curl -fsSL https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/dist-service/dist-standard-service.sh) \
  -I "git@github.com:acme/svc.git" --no-run
```

> SSH URL(`git@github.com:…`)은 호출 사용자에게 SSH 키가 등록되어 있어야 합니다. 없으면 HTTPS URL + `gh auth login` 흐름을 사용하세요.

#### 방법 1-alt: 파이프 (`curl | bash -s --`) — 비권장

```bash
# 메뉴가 필요 없는 비대화형 시나리오(CI, Packer, cloud-init)에서만 사용.
# gh auth login도 TTY를 요구하므로 GH_TOKEN 환경변수를 사전 설정해야 합니다.
GH_TOKEN="$(cat ~/.gh-token)" \
  curl -fsSL https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/dist-service/dist-standard-service.sh \
  | bash -s -- -I "https://github.com/acme/svc-a" --no-run
```

#### 방법 2: 다운로드 후 실행

```bash
curl -O https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/dist-service/dist-standard-service.sh
chmod +x dist-standard-service.sh
./dist-standard-service.sh -I "https://github.com/acme/svc-a https://github.com/acme/svc-b"
```

### 실행 흐름

```
parse_args       → 인자 파싱 + workspace 결정
                    -w 지정 시: 즉시 사용
                    생략 시: 번호 메뉴 (1) ./ [기본]  2) ../  3) custom)
detect_os        → OS / pkg manager 식별
bootstrap_tools  → git, gh, gh-auth 메뉴, docker(+compose v2), make 설치·검증
sync_all_repos   → -I 로 받은 모든 repo clone / pull --ff-only
resolve_ops_dir  → ops 디렉터리 확정 (-o 우선, 없으면 compose 보유 repo 자동)
load_compose_files  → docker-compose*.yml / compose*.yml 스캔
                      (Makefile 이미 있으면 스캔 스킵)
generate_makefile   → Makefile 없으면 compose 파일 기반으로 자동 생성
run_user_commands   → Pre-run 커맨드 루프 (빈 Enter로 종료)
choose_and_run      → make up-* 인터랙티브 메뉴 + 기본값 저장
finalize_docker_access → docker group 미적용 시 sg docker 서브셸 제안
```

### 인터랙티브 프롬프트

| 단계 | 조건 | 내용 |
|------|------|------|
| 1 | `-w` 미지정 | 워크스페이스 선택: `1) ./` / `2) ../` / `3) custom` |
| 2 | gh 이미 로그인 | 계정 액션: `1) Keep` / `2) Re-login` / `3) Switch` |
| 3 | 항상 | Pre-run 커맨드 루프 (예: `cp .env.example .env`) |
| 4 | `--no-run` 미지정 | `up-*` 타깃 번호 선택 / `c` 커스텀 / Enter(기본값) |
| 5 | 타깃 선택 후 | 실행 최종 확인: `Run now? [Y/n]` |
| 6 | docker group 미활성 | `1) sg docker 서브셸` / `2) 방법 안내` / `3) 건너뜀` |

---

## `dist-ss-tui.sh` v3.0 — REPL 버전

커맨드 입력 방식의 인터랙티브 셸. 자동완성·히스토리·저장소 매니저 내장.

### 인자

| 플래그 | 설명 | 기본값 |
|--------|------|--------|
| `-I`, `--input <repos>` | 공백 구분 Git URL | REPL에서 `/repo`로 입력 |
| `-w`, `--workspace <dir>` | 클론 대상 디렉터리 | REPL에서 `/workspace`로 선택 |
| `-o`, `--ops <name>` | ops 저장소 이름 | `/bootstrap` 시 자동 감지 |
| `-c`, `--cli` | 비대화형 CLI 모드 강제 | — |
| `--no-run` | 배포 실행 건너뜀 (CLI 모드로 전환) | — |
| `-h`, `--help` | 도움말 출력 | — |

> `--cli` / `--no-run` 지정 시 또는 stdin이 non-tty일 때 자동으로 CLI 모드로 전환됩니다.

### 실행 방법

```bash
# REPL 모드 (기본)
./dist-ss-tui.sh

# 저장소 사전 지정 (나머지는 REPL에서 설정)
./dist-ss-tui.sh -I "https://github.com/org/svc-a https://github.com/org/svc-b"

# 주요 설정 사전 지정
./dist-ss-tui.sh -I "git@github.com:org/ops.git" -w ~/work -o ops

# 비대화형 CLI 모드 (CI/자동화용)
./dist-ss-tui.sh -I "git@github.com:org/ops.git" --cli

# CLI dry-run (저장소 동기화만, 배포 없음)
./dist-ss-tui.sh -I url --no-run
```

### REPL 커맨드

| 커맨드 | 단축키 | 설명 |
|--------|--------|------|
| `/repo [url...]` | `/R` | 저장소 관리 (추가/삭제/순서변경) 또는 URL 직접 지정 |
| `/workspace [path]` | `/W` | clone 디렉터리 설정 또는 메뉴 선택 |
| `/auth [gh\|pat\|none]` | `/A` | 인증 방식 설정 또는 메뉴 선택 |
| `/bootstrap` | `/B` | 도구 설치 + 저장소 동기화 |
| `/status` | `/S` | 현재 설정 상태 표시 |
| `/dist-run` | `/D` | 검증 → 타깃 선택 → 배포 실행 |
| `/help` | `/H` | 도움말 표시 |
| `/exit` | `/E` | 종료 + 캐시 삭제 |
| `! <command>` | — | 셸 명령 실행 (언제든) |

### REPL 키 조작

| 키 | 동작 |
|----|------|
| `↑` / `↓` | 커맨드 히스토리 탐색 |
| `←` / `→` | 커서 이동 |
| `Delete` / `Backspace` | 문자 삭제 |
| `/` 로 시작 입력 | 자동완성 메뉴 표시 |
| `↑` / `↓` (자동완성 중) | 자동완성 항목 탐색 |
| `Enter` (자동완성 중) | 항목 선택 |
| `ESC` | 자동완성 닫기 |
| `k` / `j` | 메뉴에서 UP / DOWN |

### 일반적인 사용 순서

```
1. ./dist-ss-tui.sh 실행

2. /repo                          저장소 추가
   > Add Repository
   > Enter Repo URL: https://github.com/org/ops.git
   > Save & Exit

3. /workspace                     clone 위치 선택
   > Current dir  →  /home/user/project

4. /auth                          인증 방식 선택
   > gh auth login — GitHub CLI (권장)

5. /dist-run                      자동 bootstrap → 타깃 선택 → 배포
   > (Bootstrap 자동 실행)
   > Make Target: up
   > Deploy? ▶ Run Now
```

`/dist-run`은 bootstrap 미완료 시 자동으로 먼저 실행합니다.
수동 제어가 필요하면 `/bootstrap` → `/dist-run` 순서로 실행하세요.

### `/repo` — 저장소 매니저

```
━━ Repository Manager ━━
  1) https://github.com/org/ops.git
  2) https://github.com/org/api.git

  Actions
  ▶ Add Repository
    Delete Repository
    Clear All
    Change Order (Reorder)
    Save & Exit
    Cancel & Discard
```

- **Add**: URL 입력 (최대 8개)
- **Delete**: 목록에서 선택 삭제
- **Clear All**: 전체 삭제 (확인 후)
- **Change Order**: ↑↓로 드래그하여 순서 변경

URL 직접 지정도 가능합니다:

```bash
# 명령줄 인수로
./dist-ss-tui.sh -I "url1 url2"

# REPL 내에서
/repo https://github.com/org/ops.git https://github.com/org/api.git
```

### `/status` — 설정 상태

```
━━ dist-ss-tui Configuration Status ━━
  Workspace : /home/user/project          ← 설정됨 (녹색)
  Repos     : [NOT SET]                   ← 미설정 (빨강)
  Auth      : gh                          ← 설정됨
  Ops Repo  : [NOT SET]                   ← /bootstrap 시 자동 감지
  Bootstrap : [PENDING]                   ← 미완료 (노랑)
```

### `/auth` — 인증 방식

#### `gh` auth (권장)

`gh`가 없으면 `/bootstrap` 시 자동 설치됩니다. 이미 로그인 시 유지/재로그인/계정 전환 메뉴를 표시합니다.

#### Access Token (PAT)

- 마스킹 입력 (`read -s`)
- SSH URL → HTTPS 자동 변환 (`git@github.com:org/repo` → `https://github.com/org/repo`)
- `mktemp` 임시 credential 파일 생성 (`chmod 600`)
- EXIT 트랩에서 자동 삭제
- PAT 발급: GitHub → Settings → Developer settings → Personal access tokens  
  최소 권한: **Contents → Read-only**

#### No auth

공개 저장소 전용. `gh` 설치·로그인 불필요.

### 세션 캐시

| 파일 | 경로 | 내용 |
|------|------|------|
| 설정 캐시 | `/tmp/.dist-ss-tui-<UID>.cache` | 저장소·workspace·인증방식·타깃·bootstrap 상태 |
| 히스토리 | `/tmp/.dist-ss-tui_history` | REPL 커맨드 히스토리 |

각 커맨드 실행 후 자동 저장, 다음 실행 시 자동 로드합니다.

**캐시 삭제 조건**: `/dist-run` 성공 완료 / `/exit` / Ctrl+C×2 (2초 이내)

### 종료 방법

| 상황 | 종료 방법 | 캐시 |
|------|-----------|------|
| REPL 프롬프트 | `/exit` 또는 `/E` | 삭제 |
| 메뉴 중 | `q` 또는 `ESC` | 유지 |
| 어디서든 강제 | Ctrl+C × 2 (2초 이내) | 삭제 |
| 배포 완료 후 | 자동 종료 | 삭제 |

---

## 트러블슈팅

| 증상 | 원인 / 조치 |
|------|-------------|
| `curl … \| bash` 실행 시 메뉴가 안 뜨고 즉시 종료 | stdin이 파이프에 점유됨. `bash <(curl …)` 형태로 변경하거나 `--no-run` + `GH_TOKEN` 비대화형으로 사용. |
| `NO_PUBKEY 23F3D4EA75716059` / `cli.github.com … is not signed` | Debian/Ubuntu의 GitHub CLI APT 키링 파손. 스크립트가 `repair_apt_gh_keyring`으로 자동 복구, 실패 시 gh APT repo 비활성화 (gh 바이너리는 유지). |
| `permission denied while trying to connect to the docker API` | 현재 셸에 `docker` group 미적용. `usermod -aG docker` 후 `sg docker -c "$SHELL"` 서브셸 제안. 또는 로그아웃/로그인. |
| `docker compose v2 still missing` | `docker-compose-plugin` 미설치. Ubuntu base repo에는 없으므로 스크립트가 Docker 공식 repo로 재설치. 그래도 실패하면 프록시/방화벽으로 `download.docker.com` 차단 여부 확인. |
| `make … up-xxx` 실패 후 컨테이너 로그가 자동 출력됨 | 의도된 동작 (`dump_unhealthy_logs`). Up+healthy가 아닌 컨테이너의 로그를 tail. 원인 파악 후 재실행. |
| `Ops dir not found: …` | `-o <name>`이 실제 클론된 디렉터리명과 불일치. `-I` URL의 basename을 확인 (`.git` 제거 후 `basename`). |
| REPL에서 방향키가 `^[[A` 등 이스케이프 문자로 출력됨 | 터미널 에뮬레이터가 ANSI 시퀀스를 지원하지 않음. 다른 터미널 사용 또는 `--cli` 모드로 전환. |

---

## 확인 사항

스크립트 완료 후:

```bash
# docker / compose 동작 여부
docker info
docker compose version

# gh 인증 상태
gh auth status

# 기동된 스택 확인 (OPS_DIR 에서)
cd <workspace>/<ops-repo>
make ps    # 또는 docker compose ps

# 저장된 기본 타깃
cat .dist-standard.conf
```

`docker` group이 방금 추가된 직후라면 새 터미널을 열거나 `exec sg docker -c "$SHELL"` 후 위 명령을 다시 실행하세요.

---

## 관련 스크립트

- [`ec2-init/setup-ec2.sh`](../ec2-init/setup-ec2.sh) — Amazon Linux 2023 전용 초기화 + Route53 DDNS 구성
- [`ec2-init/setup-ubuntu.sh`](../ec2-init/setup-ubuntu.sh) — Ubuntu EC2 초기화 변형
