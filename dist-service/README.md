# Ubuntu Dist Standard Service (`Dist-Standard-Service.sh`)

Ubuntu(또는 Debian/Fedora/Arch/macOS) 머신에서 **임의의 Git 저장소 묶음**을 클론하고, 필요한 도구(`git`, `gh`, `docker`, `docker compose v2`, `make`)를 자동으로 설치/검증한 뒤, `Makefile` 또는 자동 생성된 `Makefile`을 통해 `docker compose` 스택을 인터랙티브 메뉴로 기동하는 범용 부트스트랩 스크립트입니다.

`ec2-init/setup-ec2.sh`(Amazon Linux 2023 전용)와 달리, 본 스크립트는 OS 패키지 매니저를 자동 감지(`apt`/`dnf`/`yum`/`pacman`/`brew`)하며 **저장소 목록을 인자로 받는 일반화 버전**입니다.

---

## English summary

`Dist-Standard-Service.sh` is a generic, cross-distro bootstrap that:

1. Detects OS / package manager (Debian-family, Fedora-family, Arch, macOS).
2. Installs and validates `git`, `gh`, `docker`, `docker compose v2`, `make`.
3. Authenticates `gh` (interactive switch / re-login menu).
4. Clones every repo passed via `-I/--input` into a chosen workspace.
5. Picks the "ops" repo (auto-detected by presence of a compose file, or `-o/--ops <name>`).
6. Auto-generates a `Makefile` if missing, then shows an interactive menu of `up-*` targets.
7. On Linux, handles the `docker` group gap (`sg docker -c …`) so you do not have to log out/in.
8. Dumps logs from unhealthy containers when a stack fails to come up.

The recommended way to run it on a fresh Ubuntu box is via **process substitution** (`bash <(curl …)`) so interactive prompts (workspace pick, `gh` account menu, target picker) keep working.

---

## 대상 환경 / Target environment

- **OS**: Ubuntu 22.04+ / Debian 12+ (1차 지원), Fedora/RHEL, Arch, macOS (Homebrew)
- **Shell**: `bash` (스크립트 내부에서 강제 사용)
- **권한**: 일반 사용자 + `sudo` 가능해야 함 (패키지 설치, `systemctl`, `usermod` 등)
- **네트워크**: GitHub(`github.com`, `cli.github.com`, `raw.githubusercontent.com`), Docker(`download.docker.com`) 접근 가능

> ⚠️ `setup-ec2.sh`처럼 root 단독 실행은 권장하지 않습니다. `gh auth login`, `docker` 그룹 적용 등은 **호출한 사용자 계정** 기준으로 동작해야 합니다.

---

## 주요 기능 / Key features

| #   | 기능 (KO)                                                                       | Feature (EN)                                                  |
| --- | ------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| 1   | OS / 패키지 매니저 자동 감지                                                    | Auto-detects OS & package manager                             |
| 2   | `git` / `gh` / `docker` / `docker compose v2` / `make` 설치·검증                | Installs & verifies toolchain                                 |
| 3   | `gh` 인증 상태 점검 + 계정 전환 인터랙티브 메뉴                                 | `gh` auth status check w/ switch/re-login menu                |
| 4   | GitHub CLI APT 키링 파손 자동 복구 (Debian/Ubuntu)                              | Auto-repairs broken `cli.github.com` APT keyring              |
| 5   | Docker 공식 APT 저장소로 설치 (Ubuntu base repo는 `docker-compose-plugin` 없음) | Installs Docker via official Docker APT repo                  |
| 6   | `docker` 그룹 미적용 셸 자동 감지 → `sg docker -c …` 래핑                       | Wraps recipes in `sg docker -c` when shell lacks docker group |
| 7   | 입력받은 모든 Git URL을 워크스페이스에 클론/`pull --ff-only`                    | Clones / fast-forward-pulls every input repo                  |
| 8   | `compose*.yml` 자동 스캔 + `Makefile` 자동 생성                                 | Scans compose files & auto-generates a `Makefile`             |
| 9   | `Makefile`의 `up-*` 타깃을 인터랙티브 메뉴로 노출 + 기본값 저장                 | Interactive menu for `up-*` targets w/ persisted default      |
| 10  | `make` 실패 시 unhealthy 컨테이너 로그 자동 덤프                                | Auto-dumps logs of unhealthy containers on failure            |

---

## 인자 / Arguments

| Flag                      | 설명 (KO)                                                                                                      | Description (EN)                                                         | Required |
| ------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ | -------- |
| `-I`, `--input <repos>`   | 클론할 Git URL 목록. 따옴표로 묶어 공백 구분, 또는 다중 인자 가능                                              | Space-separated list of Git URLs (one quoted arg or multiple positional) | ✅       |
| `-w`, `--workspace <dir>` | 클론 대상 디렉터리. 미지정 시 런타임에 선택 메뉴 표시 (`./` / `../` / custom)                                  | Workspace dir for clones. Prompts at runtime if omitted                  | ❌       |
| `-o`, `--ops <name>`      | `Makefile` / `docker-compose*.yml`을 보유한 "ops" 저장소 이름. 미지정 시 첫 번째 compose 보유 저장소 자동 선택 | "Ops" repo name; auto-detected if omitted                                | ❌       |
| `--no-run`                | 모든 설치/클론은 수행하되 마지막 compose 메뉴는 스킵                                                           | Run install/clone steps but skip the interactive compose menu            | ❌       |
| `-h`, `--help`            | 도움말 표시                                                                                                    | Show help                                                                | ❌       |

---

## 실행 방법 / How to run

> 본 스크립트는 **인터랙티브 프롬프트**(워크스페이스 선택, `gh` 계정 메뉴, 사용자 명령 입력, 타깃 선택)를 사용합니다. 따라서 `curl … | sudo bash` 와 같이 표준입력을 파이프로 점유하는 형태는 권장하지 않습니다 (`read` 호출이 무한 EOF로 빠짐).
>
> 권장 방식은 **프로세스 치환** `bash <(curl …)` 입니다. 스크립트 본문만 파이프로 받고, stdin은 터미널을 유지합니다.

### 방법 1 (권장): 파이프라인 즉시 실행 — Process substitution

```bash
# 1) 최소 실행: -I 만 지정 (워크스페이스/ops는 런타임 메뉴/자동 감지)
bash <(curl -fsSL https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/dist-service/Dist-Standard-Service.sh) \
  -I "https://github.com/acme/svc-a https://github.com/acme/svc-b"

# 2) 풀 옵션
bash <(curl -fsSL https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/dist-service/Dist-Standard-Service.sh) \
  --input "https://github.com/acme/ops https://github.com/acme/api" \
  --workspace ~/work \
  --ops ops

# 3) 설치/클론만, compose 메뉴는 스킵
bash <(curl -fsSL https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/dist-service/Dist-Standard-Service.sh) \
  -I "git@github.com:acme/svc.git" --no-run
```

> 💡 SSH URL(`git@github.com:…`)을 쓰려면 호출 사용자에게 SSH key가 등록되어 있어야 합니다. 아직 없으면 `gh` HTTPS 인증 흐름을 그대로 사용하세요 — `gh auth login`이 자동으로 호출됩니다.

### 방법 1-alt: 표준 입력 파이프 (`curl | bash -s --`) — **비권장**

```bash
# bash 가 stdin 으로 스크립트를 읽으므로, 스크립트 내부 read 가 EOF 로 즉시 종료.
# 결과: 워크스페이스/gh/타깃 선택 메뉴를 사용할 수 없습니다.
curl -fsSL https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/dist-service/Dist-Standard-Service.sh \
  | bash -s -- -I "https://github.com/acme/svc-a" --no-run
```

위 형태는 `--no-run` 과 함께, **메뉴가 필요 없는 비대화형 시나리오**(CI, Packer, cloud-init 등)에서만 사용하세요. 또한 `gh auth login`도 TTY를 요구하므로, 사전에 `GH_TOKEN`/`GITHUB_TOKEN` 환경변수를 export 해 두어야 합니다.

```bash
GH_TOKEN="$(cat ~/.gh-token)" \
  curl -fsSL https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/dist-service/Dist-Standard-Service.sh \
  | bash -s -- -I "https://github.com/acme/svc-a" --no-run
```

### 방법 2: 다운로드 후 실행

```bash
curl -O https://raw.githubusercontent.com/EDEN-TNS/aitech-aws-common/refs/heads/main/dist-service/Dist-Standard-Service.sh
chmod +x Dist-Standard-Service.sh

./Dist-Standard-Service.sh \
  -I "https://github.com/acme/svc-a https://github.com/acme/svc-b"
```

> ⚠️ `sudo ./Dist-Standard-Service.sh` 처럼 root로 직접 실행하지 마세요. `gh` 인증/`docker` 그룹/`~/.dist-standard.conf` 등이 root 홈에 묶입니다. 일반 사용자로 실행하면 스크립트가 필요 시점에만 `sudo`를 호출합니다.

---

## 실행 흐름 / Execution flow

```
parse_args      → 인자 파싱 + 워크스페이스 결정
detect_os       → OS / pkg manager 식별
bootstrap_tools → git, gh, gh-auth, docker(+compose v2), make 설치/검증
sync_all_repos  → -I 로 받은 모든 repo clone / pull --ff-only
resolve_ops_dir → ops 디렉터리 확정 (-o 우선, 없으면 compose 보유 repo 자동)
load_compose_files → docker-compose*.yml / compose*.yml 스캔
                     (Makefile 이미 있으면 스캔 스킵)
generate_makefile  → Makefile 없으면 compose 파일들 기반으로 자동 생성
                     (base 선정: docker-compose.yml/compose.yml 중 최상위)
run_user_commands  → 사용자 정의 사전 명령 루프 (예: cp .env.example .env)
choose_and_run     → make up-* 인터랙티브 메뉴 + 기본값 저장 (.dist-standard.conf)
finalize_docker_access → 현재 셸에 docker 그룹 미적용 시 sg docker 서브셸 제안
```

---

## 인터랙티브 프롬프트 / Interactive prompts

스크립트가 멈추는 위치는 다음과 같습니다.

1. **워크스페이스 선택** — `-w` 미지정 시. `1) ./` / `2) ../` / `3) custom path` 중 선택.
2. **`gh` 계정 액션** — 이미 로그인되어 있을 때. `1) Keep` / `2) Re-login` / `3) Switch`.
3. **Pre-run user commands** — 빈 줄 입력 시 종료. 예: `cp .env.example .env`.
4. **Compose 타깃 선택** — `Makefile`의 `up-*` 목록. 숫자/`c`(custom)/`Enter`(default).
5. **실행 직전 최종 확인** — `Run now? [Y/n]`.
6. **`docker` 그룹 적용** — 현재 셸에 그룹 없을 때 `1) exec sg docker -c $SHELL` 등.

---

## 영속화되는 상태 / Persisted state

| 파일                  | 위치                             | 용도                                                                                                  |
| --------------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `.dist-standard.conf` | `${OPS_DIR}/.dist-standard.conf` | 마지막으로 선택한 `make` 타깃 (`LAST_TARGET`)과 실행 시각 (`LAST_RUN`). 다음 실행 시 기본값으로 사용. |
| `Makefile`            | `${OPS_DIR}/Makefile`            | 자동 생성된 경우. 기존에 존재하면 절대 덮어쓰지 않음.                                                 |

`.dist-standard.conf` 가 신규로 들어가는 저장소면 `.gitignore`에 추가하는 것을 권장합니다.

---

## 트러블슈팅 / Troubleshooting

| 증상                                                                                         | 원인 / 조치                                                                                                                                                                      |
| -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `curl … \| sudo bash` 실행 시 메뉴가 안 뜨고 즉시 종료                                       | stdin이 파이프에 점유됨. `bash <(curl …)` 형태로 변경하거나 `--no-run`+`GH_TOKEN` 비대화형으로 사용.                                                                             |
| `NO_PUBKEY 23F3D4EA75716059` / `cli.github.com … is not signed`                              | Debian/Ubuntu의 GitHub CLI APT 키링 파손. 스크립트가 `repair_apt_gh_keyring`로 자동 복구하며, 실패 시 gh APT repo 자체를 비활성화 (gh 바이너리는 그대로 유지).                   |
| `permission denied while trying to connect to the docker API at unix:///var/run/docker.sock` | 현재 셸에 `docker` 그룹 미적용. 스크립트가 `usermod -aG docker` 후 `sg docker -c "$SHELL"` 서브셸을 제안. 또는 로그아웃/로그인.                                                  |
| `docker compose v2 still missing`                                                            | `docker-compose-plugin` 미설치. Ubuntu base repo에는 없으므로 스크립트가 Docker 공식 repo로 재설치. 그래도 실패하면 회사 프록시/방화벽으로 `download.docker.com` 차단 여부 확인. |
| `make -C … up-xxx` 실패 후 자동으로 컨테이너 로그가 쏟아짐                                   | 의도된 동작 (`dump_unhealthy_logs`). Up+healthy 가 아닌 컨테이너 80줄씩 tail. 원인 파악 후 재실행.                                                                               |
| `Ops dir not found: …`                                                                       | `-o <name>`이 실제 클론된 디렉터리명과 불일치. `-I`의 URL repo 베이스네임을 확인 (`.git` 제거 후 basename).                                                                      |

---

## 확인 사항 / Verification

스크립트 완료 후:

```bash
# 1) docker / compose 동작 여부
docker info
docker compose version

# 2) gh 인증 상태
gh auth status

# 3) 기동된 스택 확인 (OPS_DIR 에서)
cd <workspace>/<ops-repo>
make ps   # 또는 docker compose ps

# 4) 저장된 기본 타깃
cat .dist-standard.conf
```

`docker` 그룹이 방금 추가된 직후라면 새 터미널을 열거나 `exec sg docker -c "$SHELL"` 후 위 명령을 다시 실행하세요.

---

## 관련 스크립트 / Related scripts

- [`ec2-init/setup-ec2.sh`](../ec2-init/setup-ec2.sh) — Amazon Linux 2023 전용 초기화 + Route53 DDNS 구성
- [`ec2-init/setup-ubuntu.sh`](../ec2-init/setup-ubuntu.sh) — Ubuntu EC2 초기화 변형
