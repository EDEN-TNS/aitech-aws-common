#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Dist-Standard-Service.sh
#
# 범용 배포 부트스트랩. Dist-Guardrails-Service.sh 와 동일한 OS / git / gh /
# compose 흐름을 사용하지만, 저장소 목록을 하드코딩된 Guardrails 구성 요소
# 집합 대신 -I / --input 으로 사용자가 직접 지정한다.
# Generic distribution bootstrap. Same OS / git / gh / compose flow as
# Dist-Guardrails-Service.sh, but the repo list is supplied by the user
# via -I / --input instead of the hard-coded Guardrails component set.
#
# 사용법:
# Usage:
#   ./Dist-Standard-Service.sh \
#       -I "https://github.com/acme/svc-a https://github.com/acme/svc-b"
#   ./Dist-Standard-Service.sh \
#       --input "git@github.com:acme/svc.git" \
#       --workspace ~/work --ops svc
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────
WORKSPACE_DIR=""        # parent dir that will hold every cloned repo
OPS_NAME=""             # which cloned repo is the "ops" project
declare -a INPUT_REPOS=()
NO_RUN=0

# ── Pretty print ─────────────────────────────────────────────────────
# All status helpers write to stderr so command-substituted callers
# (e.g. `name=$(sync_repo …)`) capture only the real return value.
c_reset=$'\033[0m'; c_b=$'\033[1m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_c=$'\033[36m'
log()  { printf '%s▶%s %s\n' "${c_c}" "${c_reset}" "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "${c_g}" "${c_reset}" "$*" >&2; }
warn() { printf '%s!%s %s\n' "${c_y}" "${c_reset}" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "${c_r}" "${c_reset}" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Dist-Standard-Service.sh — 범용 저장소 + compose 부트스트랩
Dist-Standard-Service.sh — generic repo + compose bootstrap

필수:
Required:
  -I, --input  <repos>     공백으로 구분된 git 저장소 URL 목록 (하나 또는 여러 개).
                           셸이 하나의 인자로 유지하도록 전체 값을 따옴표로 감싸세요.
  -I, --input  <repos>     Space-separated list of git repo URLs (one or many).
                           Quote the whole value so the shell keeps it as one arg.

선택:
Optional:
  -w, --workspace <dir>    저장소를 clone 할 워크스페이스 디렉터리.
                           생략하면 스크립트가 실행 중에 묻습니다:
                             1) 현재 디렉터리 (./)   [기본값]
                             2) 상위 디렉터리  (../)
                             3) 사용자 지정 경로
  -w, --workspace <dir>    Workspace dir to clone repos into.
                           If omitted, the script asks at runtime:
                             1) current dir (./)   [default]
                             2) parent dir  (../)
                             3) custom path
  -o, --ops <name>         Makefile / docker-compose*.yml 을 보유한 저장소 이름.
                           --input 의 첫 번째 저장소를 기본값으로 사용합니다.
  -o, --ops <name>         Repo name that holds Makefile / docker-compose*.yml.
                           Defaults to the first repo in --input.
      --no-run             대화형 compose 메뉴를 건너뜁니다.
      --no-run             Skip the interactive compose menu.
  -h, --help               이 도움말을 표시합니다.
  -h, --help               Show this help.

예시:
Examples:
  ./Dist-Standard-Service.sh -I "https://github.com/acme/svc-a https://github.com/acme/svc-b"
  ./Dist-Standard-Service.sh --input "git@github.com:acme/ops.git git@github.com:acme/api.git" \
                             --workspace ~/work --ops ops
EOF
}

# ── Argparse ─────────────────────────────────────────────────────────
parse_args() {
  while (( $# )); do
    case "$1" in
      -I|--input)
        [[ $# -ge 2 ]] || die "--input needs a value"
        shift  # consume the flag
        # Greedy: accept either
        #   -I "url1 url2 url3"        (one quoted, whitespace-separated)
        #   -I url1 url2 url3          (multiple positional, until next flag)
        # Keep eating until next flag-like token or end of argv.
        while (( $# )) && [[ "$1" != -* ]]; do
          # split each token on whitespace (handles single-quoted multi-url case too)
          read -r -a _tmp <<< "$1"
          INPUT_REPOS+=("${_tmp[@]}")
          shift
        done
        ;;
      -w|--workspace) WORKSPACE_DIR="$2"; shift 2 ;;
      -o|--ops)       OPS_NAME="$2"; shift 2 ;;
      --no-run)       NO_RUN=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) die "Unknown arg: $1 (try --help)" ;;
    esac
  done

  [[ ${#INPUT_REPOS[@]} -gt 0 ]] || { usage; die "--input is required"; }
  resolve_workspace
  mkdir -p "${WORKSPACE_DIR}"
  WORKSPACE_DIR="$(cd "${WORKSPACE_DIR}" && pwd)"
  ok "Workspace resolved: ${WORKSPACE_DIR}"
}

# Ask the user where to clone repos, unless -w/--workspace already set it.
resolve_workspace() {
  [[ -n "${WORKSPACE_DIR}" ]] && return

  local cwd="${PWD}"
  local parent; parent="$(cd "${cwd}/.." && pwd)"

  echo ""
  echo "${c_b}── Choose clone workspace ──${c_reset}" >&2
  echo "   1) Current dir ./   (${cwd})   [default]" >&2
  echo "   2) Parent dir  ../  (${parent})" >&2
  echo "   3) Custom path" >&2

  local pick custom
  read -r -p "Selection [1]: " pick
  case "${pick:-1}" in
    1|"") WORKSPACE_DIR="${cwd}" ;;
    2)    WORKSPACE_DIR="${parent}" ;;
    3)
      read -r -p "Enter custom path: " custom
      [[ -n "${custom}" ]] || die "Custom path required"
      WORKSPACE_DIR="${custom/#\~/$HOME}"
      ;;
    *) die "Invalid selection: ${pick}" ;;
  esac
}

# ── OS / tooling (same as guardrails variant) ────────────────────────
detect_os() {
  OS_KIND=""; OS_FAMILY=""; PKG_MGR=""; PKG_INSTALL=""
  case "$(uname -s)" in
    Darwin)
      OS_KIND="macos"
      if command -v brew >/dev/null 2>&1; then
        PKG_MGR="brew"; PKG_INSTALL="brew install"
      else
        warn "Homebrew not found. Install from https://brew.sh"
      fi
      ;;
    Linux)
      OS_KIND="linux"
      if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID_LIKE:-$ID}" in
          *debian*|*ubuntu*)
            OS_FAMILY="debian"; PKG_MGR="apt"
            PKG_INSTALL="sudo apt-get update && sudo apt-get install -y" ;;
          *fedora*|*rhel*|*centos*|*rocky*|*almalinux*)
            OS_FAMILY="fedora"
            if command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi
            PKG_INSTALL="sudo ${PKG_MGR} install -y" ;;
          *arch*) OS_FAMILY="arch"; PKG_MGR="pacman"; PKG_INSTALL="sudo pacman -S --noconfirm" ;;
          *) OS_FAMILY="unknown" ;;
        esac
      fi
      ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
  ok "OS: ${OS_KIND} (${OS_FAMILY:-unknown}), pkg=${PKG_MGR:-none}"
}

install_pkg() {
  local pkg="$1"
  [[ -n "${PKG_INSTALL}" ]] || die "No package manager — install ${pkg} manually."
  log "Installing ${pkg} …"
  # shellcheck disable=SC2086
  eval "${PKG_INSTALL} ${pkg}"
}

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  if command -v "${cmd}" >/dev/null 2>&1; then
    ok "${cmd}: $(command -v "${cmd}")"
  else
    warn "${cmd} missing — installing"
    install_pkg "${pkg}"
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} still missing"
  fi
}

ensure_gh_auth() {
  if ! gh auth status >/dev/null 2>&1; then
    log "gh not logged in — launching 'gh auth login'"
    gh auth login
    gh auth status >/dev/null 2>&1 || die "gh auth login failed"
    return
  fi

  # Loop the account menu: re-login / switch can be repeated as many times
  # as needed. Only "Keep current account" (option 1) breaks out and lets the
  # script proceed — so after a switch the user always re-confirms the active
  # account before continuing.
  local cur pick
  while true; do
    cur="$(gh api user --jq .login 2>/dev/null || echo 'unknown')"
    ok "gh currently authenticated as: ${cur}"

    echo ""
    echo "${c_b}── gh account action ──${c_reset}"
    echo "   1) Keep current account (${cur})  [default] → proceed"
    echo "   2) Re-login (gh auth login)"
    echo "   3) Switch account (gh auth switch)"

    read -r -p "Selection [1]: " pick
    case "${pick:-1}" in
      1|"")
        ok "Keeping ${cur}"
        break
        ;;
      2)
        log "Re-running gh auth login"
        gh auth login || warn "gh auth login failed — try again"
        ;;
      3)
        log "Available accounts:"
        gh auth status 2>&1 | grep -E 'Logged in to' || true
        if ! gh auth switch; then
          warn "gh auth switch failed — falling back to 'gh auth login'"
          gh auth login || warn "gh auth login failed — try again"
        fi
        ;;
      *)
        warn "Invalid selection — choose 1, 2, or 3"
        ;;
    esac
  done

  gh auth status >/dev/null 2>&1 || die "gh not authenticated after action"
  local now
  now="$(gh api user --jq .login 2>/dev/null || echo 'unknown')"
  ok "Active gh user: ${now}"
}

# Detect / repair the GitHub CLI APT repo keyring on Debian/Ubuntu.
# Symptom: 'apt-get update' emits NO_PUBKEY 23F3D4EA75716059 or
# "cli.github.com … is not signed" — every subsequent install fails.
# Strategy: if gh is already installed, prefer fixing keyring; if the fix
# fails, disable the gh repo (gh keeps working from the existing binary).
repair_apt_gh_keyring() {
  [[ "${OS_FAMILY}" == "debian" ]] || return 0
  local out
  out="$(sudo apt-get update 2>&1 || true)"
  if ! grep -qE 'NO_PUBKEY[[:space:]]+23F3D4EA75716059|cli\.github\.com.*not signed' <<<"${out}"; then
    return 0
  fi
  warn "Broken GitHub CLI APT keyring detected — repairing"
  sudo mkdir -p /etc/apt/keyrings
  if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null; then
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    if sudo apt-get update -y 2>&1 | grep -qE 'NO_PUBKEY|not signed'; then
      warn "Keyring refresh did not clear apt — disabling gh APT repo (gh binary still works)"
      sudo rm -f /etc/apt/sources.list.d/github-cli.list \
                 /usr/share/keyrings/githubcli-archive-keyring.gpg \
                 /etc/apt/keyrings/githubcli-archive-keyring.gpg
      sudo apt-get update -y >/dev/null
    else
      ok "GitHub CLI keyring restored"
    fi
  else
    warn "Could not fetch gh keyring — disabling gh APT repo"
    sudo rm -f /etc/apt/sources.list.d/github-cli.list \
               /usr/share/keyrings/githubcli-archive-keyring.gpg \
               /etc/apt/keyrings/githubcli-archive-keyring.gpg
    sudo apt-get update -y >/dev/null
  fi
}

# Install Docker on Debian/Ubuntu via Docker's official APT repo.
# Required because the Ubuntu base repo does NOT ship docker-compose-plugin.
install_docker_debian() {
  log "Installing Docker via Docker official APT repo"
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  local distro codename arch
  distro="$(. /etc/os-release && echo "${ID}")"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  arch="$(dpkg --print-architecture)"
  # download.docker.com only hosts ubuntu/ and debian/ paths.
  case "${distro}" in
    ubuntu|debian) ;;
    *) distro="ubuntu" ;;
  esac
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} ${codename} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

# Install Docker on RHEL family (Rocky, AlmaLinux, CentOS, RHEL, Fedora) via
# Docker's official dnf/yum repo. Required because RHEL base repos do NOT ship
# docker-ce or docker-compose-plugin — 'dnf install docker' only pulls the
# podman-docker shim, which has no 'docker compose' subcommand.
install_docker_rhel() {
  log "Installing Docker via Docker official ${PKG_MGR} repo"
  # Drop podman-docker shim if present — its fake 'docker' lacks compose v2.
  sudo "${PKG_MGR}" remove -y podman-docker 2>/dev/null || true

  # config-manager plugin: dnf-plugins-core (dnf) or yum-utils (yum).
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y dnf-plugins-core
  else
    sudo yum install -y yum-utils
  fi

  # download.docker.com hosts centos/, rhel/, fedora/ paths only.
  # Rocky / AlmaLinux / CentOS Stream all use the centos repo ($releasever
  # in docker-ce.repo resolves correctly on EL8/EL9).
  local repo_distro
  case "$(. /etc/os-release && echo "${ID}")" in
    fedora) repo_distro="fedora" ;;
    rhel)   repo_distro="rhel" ;;
    *)      repo_distro="centos" ;;
  esac
  local repo_url="https://download.docker.com/linux/${repo_distro}/docker-ce.repo"

  # dnf4 (Rocky 8/9) uses 'config-manager --add-repo'; dnf5 (Fedora 41+) uses
  # 'config-manager addrepo --from-repofile='. Try dnf4 form, then dnf5, then yum.
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf config-manager --add-repo "${repo_url}" 2>/dev/null \
      || sudo dnf config-manager addrepo --from-repofile="${repo_url}"
  else
    sudo yum-config-manager --add-repo "${repo_url}"
  fi

  sudo "${PKG_MGR}" install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

ensure_docker() {
  # 1. binary
  if ! command -v docker >/dev/null 2>&1; then
    log "docker missing — installing"
    case "${OS_KIND}" in
      macos) install_pkg "--cask docker" ;;
      linux)
        case "${OS_FAMILY}" in
          debian)
            repair_apt_gh_keyring
            install_docker_debian
            ;;
          fedora) install_docker_rhel ;;
          arch)   install_pkg "docker docker-compose" ;;
          *)      die "Unsupported Linux family for docker install: ${OS_FAMILY}" ;;
        esac
        ;;
      *) die "Unsupported OS for docker install: ${OS_KIND}" ;;
    esac
    command -v docker >/dev/null 2>&1 || die "docker install failed"
  fi
  ok "docker: $(command -v docker)"

  # 2. daemon + socket access
  # Distinguish three states:
  #   a) docker info OK as current user           → daemon up + group OK
  #   b) docker info fails, but `sudo docker info` OK → daemon up, current
  #      shell lacks 'docker' group access (perm denied on /var/run/docker.sock)
  #   c) `sudo docker info` also fails             → daemon truly offline
  DAEMON_NEEDS_SG=0
  if docker info >/dev/null 2>&1; then
    ok "docker daemon: running"
  elif sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then
    warn "Docker daemon is running, but current shell can't reach the socket"
    warn "Likely cause: ${USER:-$(id -un)} not in the 'docker' group yet"
    DAEMON_NEEDS_SG=1
    ok "docker daemon: running (via sudo probe)"
  else
    case "${OS_KIND}" in
      linux)
        log "Starting docker daemon (systemctl enable --now docker)"
        sudo systemctl enable --now docker || die "Failed to start docker daemon"
        ;;
      macos)
        warn "Docker daemon not running. Launching Docker.app …"
        open -ga Docker 2>/dev/null || true
        log "Waiting up to 60s for docker daemon …"
        local i
        for i in {1..30}; do
          docker info >/dev/null 2>&1 && break
          sleep 2
        done
        ;;
    esac
    docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1 \
      || die "docker daemon offline — start it manually and re-run"
    ok "docker daemon: running"
  fi

  # 3. user in docker group (Linux only)
  # Two distinct checks:
  #   a) /etc/group via `getent group docker` — file-level membership
  #   b) current process supplementary groups via `id -nG` (no arg) — what
  #      the kernel actually uses for socket ACL decisions
  # `id -nG <username>` reads /etc/group and lies about active access:
  # after `usermod -aG` the username is in (a) but the existing shell still
  # lacks (b) until logout/login or `newgrp`. So we treat (b) as truth for
  # the DAEMON_NEEDS_SG decision.
  if [[ "${OS_KIND}" == "linux" ]]; then
    local me="${USER:-$(id -un)}"
    if ! getent group docker 2>/dev/null | grep -qE "(:|,)${me}(,|\$)"; then
      log "Adding ${me} to 'docker' group (/etc/group)"
      if ! sudo usermod -aG docker "${me}"; then
        warn "usermod failed — docker calls may need sudo"
      fi
    else
      ok "${me} is in /etc/group docker"
    fi
    # Truth check: does THIS shell actually carry the docker group?
    if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      ok "current shell has 'docker' supplementary group"
      DAEMON_NEEDS_SG=0
    else
      warn "Current shell lacks 'docker' supplementary group — docker socket calls will use 'sg docker -c'"
      DAEMON_NEEDS_SG=1
    fi
  fi
  export DAEMON_NEEDS_SG

  # 4. docker compose v2 plugin
  if ! docker compose version >/dev/null 2>&1; then
    log "docker compose v2 missing — installing plugin"
    case "${OS_FAMILY}" in
      debian)
        # Ubuntu base repo lacks docker-compose-plugin. Go through Docker
        # official repo path — also repairs gh keyring on the way.
        repair_apt_gh_keyring
        install_docker_debian
        ;;
      fedora) install_docker_rhel ;;
      arch)   install_pkg "docker-compose" ;;
      *)      warn "Install 'docker compose' v2 plugin manually for ${OS_KIND}" ;;
    esac
    docker compose version >/dev/null 2>&1 || die "docker compose v2 still missing"
  fi
  ok "docker compose: $(docker compose version --short 2>/dev/null || echo unknown)"
}

ensure_make() {
  if command -v make >/dev/null 2>&1; then
    ok "make: $(command -v make)"
    return
  fi
  log "make missing — installing"
  install_pkg make
  command -v make >/dev/null 2>&1 || die "make install failed"
}

install_node_debian() {
  log "Installing Node.js 20 LTS via NodeSource (Debian/Ubuntu)"
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
}

install_node_rhel() {
  log "Installing Node.js 20 LTS via NodeSource (RHEL/Fedora)"
  curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo -E bash -
  sudo "${PKG_MGR}" install -y nodejs
}

ensure_node() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    ok "node: $(node --version), npm: $(npm --version)"; return
  fi
  log "Node.js missing — installing Node.js 20 LTS"
  case "${OS_KIND}" in
    macos) install_pkg "node@20" ;;
    linux)
      case "${OS_FAMILY}" in
        debian) install_node_debian ;;
        fedora) install_node_rhel ;;
        arch)   install_pkg "nodejs npm" ;;
        *)      die "Unsupported Linux family for Node.js: ${OS_FAMILY}" ;;
      esac ;;
    *) die "Unsupported OS for Node.js: ${OS_KIND}" ;;
  esac
  command -v node >/dev/null 2>&1 || die "Node.js install failed"
  ok "node: $(node --version), npm: $(npm --version)"
}

bootstrap_tools() {
  ensure_cmd git
  ensure_cmd gh
  ensure_gh_auth
  ensure_docker
  ensure_make
  ensure_node
}

# ── Repo helpers ─────────────────────────────────────────────────────
repo_name_from_url() {
  local u="$1"
  u="${u%.git}"
  basename "${u}"
}

sync_repo() {
  local url="$1"
  local name; name="$(repo_name_from_url "${url}")"
  local target="${WORKSPACE_DIR}/${name}"

  if [[ -d "${target}/.git" ]]; then
    log "pull ${name}"
    git -C "${target}" fetch --all --prune >&2
    local branch; branch="$(git -C "${target}" symbolic-ref --quiet --short HEAD || echo main)"
    git -C "${target}" pull --ff-only origin "${branch}" >&2 || warn "${name}: pull skipped"
  elif [[ -e "${target}" ]]; then
    warn "${target} exists but not a git repo — skipping"
  else
    log "clone ${name} → ${target}"
    git clone "${url}" "${target}" >&2
  fi
  printf '%s\n' "${name}"
}

sync_all_repos() {
  log "Workspace: ${WORKSPACE_DIR}"
  SYNCED_NAMES=()
  local url name
  for url in "${INPUT_REPOS[@]}"; do
    name="$(sync_repo "${url}")"
    SYNCED_NAMES+=("${name}")
  done
  ok "Synced: ${SYNCED_NAMES[*]}"
}

# ── Pick ops dir ─────────────────────────────────────────────────────
# Recursive search for docker-compose*.{yml,yaml} / compose.{yml,yaml}.
# Prunes noisy dirs (.git, node_modules, vendor, dist, build) so we don't
# trip on bundled examples. maxdepth 6 keeps the scan bounded.
find_compose_files() {
  local root="$1"
  find "${root}" \
    \( -name .git -o -name node_modules -o -name vendor -o -name dist -o -name build -o -name .venv -o -name venv -o -name __pycache__ \) -prune -o \
    -maxdepth 6 -type f \
    \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) \
    -print 2>/dev/null
}

resolve_ops_dir() {
  if [[ -z "${OPS_NAME}" ]]; then
    # auto: first repo whose dir (or any subdir) holds a compose file
    local n
    for n in "${SYNCED_NAMES[@]}"; do
      if [[ -n "$(find_compose_files "${WORKSPACE_DIR}/${n}" | head -n1)" ]]; then
        OPS_NAME="${n}"; break
      fi
    done
    [[ -n "${OPS_NAME}" ]] || OPS_NAME="${SYNCED_NAMES[0]}"
  fi
  OPS_DIR="${WORKSPACE_DIR}/${OPS_NAME}"
  [[ -d "${OPS_DIR}" ]] || die "Ops dir not found: ${OPS_DIR}"
  CONF_FILE="${OPS_DIR}/.dist-standard.conf"
  ok "Ops project: ${OPS_DIR}"
}


# ── Compose / Makefile (same shape as guardrails variant) ────────────
# Paths in COMPOSE_FILES are RELATIVE to OPS_DIR so 'docker compose -f <path>'
# resolves build contexts inside the yml as expected (compose uses the yml's
# directory as the project dir).
load_compose_files() {
  COMPOSE_FILES=()
  # Skip compose scan entirely when Makefile already present — the menu
  # parses Makefile directly for up-* targets, no scan needed.
  if [[ -f "${OPS_DIR}/Makefile" ]]; then
    ok "Makefile present — skipping docker-compose* scan"
    return
  fi
  local abs rel
  while IFS= read -r abs; do
    [[ -z "${abs}" ]] && continue
    rel="${abs#${OPS_DIR}/}"
    COMPOSE_FILES+=("${rel}")
  done < <(find_compose_files "${OPS_DIR}" | sort)
  if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
    warn "No docker-compose*.yml under ${OPS_DIR} — nothing to run"
    NO_RUN=1
    return
  fi
  log "Compose files: ${COMPOSE_FILES[*]}"
}

generate_makefile() {
  local mk="${OPS_DIR}/Makefile"
  [[ -f "${mk}" ]] && { ok "Makefile present"; return; }
  [[ ${#COMPOSE_FILES[@]} -gt 0 ]] || return
  warn "Makefile missing — generating from compose files"

  # Pick "base" compose file: prefer docker-compose.yml or compose.yml at the
  # shallowest depth. Tags for the rest are derived from path + filename so
  # files under subdirs (e.g. docker/docker-compose.yml) get unique targets.
  local base="" f bn
  local shallowest=99 depth
  for f in "${COMPOSE_FILES[@]}"; do
    bn="$(basename "${f}")"
    if [[ "${bn}" == "docker-compose.yml" || "${bn}" == "compose.yml" \
       || "${bn}" == "docker-compose.yaml" || "${bn}" == "compose.yaml" ]]; then
      depth="$(awk -F/ '{print NF}' <<<"${f}")"
      if (( depth < shallowest )); then
        shallowest="${depth}"
        base="${f}"
      fi
    fi
  done

  {
    echo "SHELL := /bin/bash"
    echo ""
    echo "# Auto-generated by Dist-Standard-Service.sh"
    echo ""
    local flags=""
    [[ -n "${base}" ]] && flags="-f ${base}"
    echo ".PHONY: help up down ps logs build clean"
    echo ""
    echo "help:"
    echo -e "\t@grep -E '^[a-zA-Z0-9_-]+:.*?## ' \$(MAKEFILE_LIST) | awk 'BEGIN{FS=\":.*?## \"};{printf \"  %-30s %s\\n\", \$\$1, \$\$2}'"
    echo ""
    local dir tag dtag
    for f in "${COMPOSE_FILES[@]}"; do
      [[ "${f}" == "${base}" ]] && continue
      bn="$(basename "${f}")"
      dir="$(dirname "${f}")"
      # strip extension FIRST, then known prefixes — order matters so that
      # bare 'compose.yml' / 'docker-compose.yml' reduce to "" cleanly.
      tag="${bn%.yml}"; tag="${tag%.yaml}"
      tag="${tag#docker-compose.}"; tag="${tag#docker-compose}"
      tag="${tag#compose.}"; tag="${tag#compose}"
      # if filename was bare 'docker-compose.yml'/'compose.yml', tag is empty
      # if file lives in subdir, prefix with sanitized dir for uniqueness
      if [[ "${dir}" != "." ]]; then
        dtag="${dir//\//-}"
        if [[ -n "${tag}" ]]; then
          tag="${dtag}-${tag}"
        else
          tag="${dtag}"
        fi
      fi
      # final safety: skip if tag still empty (shouldn't happen)
      [[ -z "${tag}" ]] && continue
      echo "up-${tag}: ## up: ${f}"
      echo -e "\tdocker compose ${flags} -f ${f} up -d"
      echo "down-${tag}: ## down: ${f}"
      echo -e "\tdocker compose ${flags} -f ${f} down"
      echo ""
    done
    if [[ -n "${base}" ]]; then
      echo "up: ## up base (${base})"
      echo -e "\tdocker compose ${flags} up -d"
      echo "down: ## down base"
      echo -e "\tdocker compose ${flags} down"
      echo "ps:"
      echo -e "\tdocker compose ${flags} ps"
      echo "logs:"
      echo -e "\tdocker compose ${flags} logs -f --tail=200"
      echo "build:"
      echo -e "\tdocker compose ${flags} build"
      echo "clean:"
      echo -e "\tdocker compose ${flags} down -v --remove-orphans"
    fi
  } > "${mk}"
  ok "Generated ${mk}"
}

# ── Interactive menu + persisted default ─────────────────────────────
# List public Makefile targets. Prefers 'up-*' (compose-lifecycle convention)
# but falls back to ALL non-special targets so any user-authored Makefile
# (which may use plain 'up', 'start', 'deploy' etc.) still drives the menu.
# Excludes: .PHONY, .DEFAULT, help, list-targets, blank/comment lines.
list_make_up_targets() {
  local mk="${OPS_DIR}/Makefile"
  [[ -f "${mk}" ]] || return
  local all up_only
  # Parse target names. Targets are lines like 'name:' or 'name: deps' at
  # column 0. Skip Make internals and helper/meta targets.
  all="$(awk -F: '
    /^[A-Za-z0-9_.\/-]+[ \t]*:/ {
      name = $1
      sub(/[ \t]+$/, "", name)
      if (name ~ /^\./) next
      if (name == "help" || name == "list-targets") next
      print name
    }
  ' "${mk}" | sort -u)"
  up_only="$(grep -E '^up(-|$)' <<<"${all}" || true)"
  if [[ -n "${up_only}" ]]; then
    printf '%s\n' "${up_only}"
  else
    printf '%s\n' "${all}"
  fi
}

load_default() {
  [[ -f "${CONF_FILE}" ]] || { DEFAULT_TARGET=""; return; }
  # shellcheck disable=SC1090
  . "${CONF_FILE}"
  DEFAULT_TARGET="${LAST_TARGET:-}"
}

save_default() {
  printf 'LAST_TARGET=%q\nLAST_RUN=%q\n' "$1" "$(date -u +%FT%TZ)" > "${CONF_FILE}"
  ok "Saved default → $1"
}

# Run arbitrary prep commands in OPS_DIR before the make menu. Loops: prompt,
# run, prompt again — empty input (Enter) ends the loop and proceeds. Handy
# for steps like 'cp .env.example .env'. Commands run through a shell so pipes
# / redirects work. On Linux without the docker group, wrap in 'sg docker -c'
# so docker-touching commands still reach the socket.
run_user_commands() {
  [[ -d "${OPS_DIR}" ]] || return 0
  echo "" >&2
  echo "${c_b}── Pre-run user commands ──${c_reset}" >&2
  echo "Commands run in: ${OPS_DIR}" >&2
  echo "Example: cp .env.example .env   |   Press Enter on empty line to continue." >&2

  local ucmd rc
  while true; do
    read -r -p "Please enter a user command: " ucmd
    # trim leading/trailing whitespace
    ucmd="${ucmd#"${ucmd%%[![:space:]]*}"}"
    ucmd="${ucmd%"${ucmd##*[![:space:]]}"}"
    [[ -z "${ucmd}" ]] && break
    log "Running: ${ucmd}"
    rc=0
    if [[ "${OS_KIND}" == "linux" ]] \
       && [[ "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] \
       && command -v sg >/dev/null 2>&1; then
      sg docker -c "cd \"${OPS_DIR}\" && ${ucmd}" || rc=$?
    else
      ( cd "${OPS_DIR}" && bash -c "${ucmd}" ) || rc=$?
    fi
    if (( rc != 0 )); then
      warn "Command exited with ${rc}"
    else
      ok "Command done"
    fi
  done
}

choose_and_run() {
  [[ "${NO_RUN}" -eq 1 ]] && { warn "--no-run set, skipping menu"; return; }
  [[ -f "${OPS_DIR}/Makefile" ]] || { warn "No Makefile, skipping menu"; return; }
  load_default
  TARGETS=()
  while IFS= read -r _line; do
    TARGETS+=("${_line}")
  done < <(list_make_up_targets)
  [[ ${#TARGETS[@]} -gt 0 ]] || { warn "No up-* targets"; return; }

  echo ""
  echo "${c_b}── Choose compose target to run ──${c_reset}"
  local i=1
  for t in "${TARGETS[@]}"; do
    if [[ "${t}" == "${DEFAULT_TARGET}" ]]; then
      printf '  %s%2d)%s %s %s(default)%s\n' "${c_g}" "$i" "${c_reset}" "$t" "${c_y}" "${c_reset}"
    else
      printf '   %2d) %s\n' "$i" "$t"
    fi
    ((i++))
  done
  printf '    %sc)%s Custom — type your own make target (e.g. up-p1-p2-all)\n' "${c_c}" "${c_reset}"

  read -r -p "Selection [Enter = ${DEFAULT_TARGET:-none}]: " pick
  local target=""
  if [[ -z "${pick}" ]]; then
    [[ -n "${DEFAULT_TARGET}" ]] || die "No default — pick a number"
    target="${DEFAULT_TARGET}"
  elif [[ "${pick}" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#TARGETS[@]} )); then
    target="${TARGETS[$((pick-1))]}"
  elif [[ "${pick}" == [Cc] || "${pick}" == "custom" ]]; then
    read -r -p "Enter custom make target: " target
    target="${target#"${target%%[![:space:]]*}"}"  # ltrim
    target="${target%"${target##*[![:space:]]}"}"   # rtrim
    [[ -n "${target}" ]] || die "Custom target required"
  else
    target="${pick}"
  fi

  save_default "${target}"

  # If current shell lacks 'docker' supplementary group (Linux), wrap exec
  # in `sg docker -c` so make recipes can talk to /var/run/docker.sock
  # without a re-login. Trust ensure_docker's DAEMON_NEEDS_SG flag.
  local cmd="make -C \"${OPS_DIR}\" ${target}"
  local wrapped="${cmd}"
  if [[ "${OS_KIND}" == "linux" ]] \
     && [[ "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] \
     && command -v sg >/dev/null 2>&1; then
    wrapped="sg docker -c 'cd \"${OPS_DIR}\" && make ${target}'"
  fi

  echo "" >&2
  echo "${c_b}▶ Will execute:${c_reset}  ${wrapped}" >&2
  read -r -p "Run now? [Y/n]: " confirm
  case "${confirm:-Y}" in
    [Nn]*)
      warn "Skipped (target saved as default — re-run script to execute)"
      return
      ;;
  esac
  log "Running: ${wrapped}"
  local exit_code=0
  if [[ "${wrapped}" == sg* ]]; then
    eval "${wrapped}" || exit_code=$?
  else
    ( cd "${OPS_DIR}" && make "${target}" ) || exit_code=$?
  fi
  if (( exit_code != 0 )); then
    dump_unhealthy_logs
    return "${exit_code}"
  fi
}

# When make fails, surface logs from compose-managed containers that
# aren't Up+healthy so the root cause is visible without re-running.
# Project-agnostic: lists every container then filters by health status.
# Tails 80 lines per failing service.
dump_unhealthy_logs() {
  echo "" >&2
  warn "Compose stack failed — collecting logs from unhealthy containers"
  local use_sg=0
  if [[ "${OS_KIND}" == "linux" ]] \
     && [[ "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] \
     && command -v sg >/dev/null 2>&1; then
    use_sg=1
  fi

  local listing
  if (( use_sg )); then
    listing="$(sg docker -c 'docker ps -a --format "{{.Names}}\t{{.Status}}"' 2>/dev/null || true)"
  else
    listing="$(docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null || true)"
  fi
  [[ -n "${listing}" ]] || { warn "No containers found"; return; }

  while IFS=$'\t' read -r name status; do
    [[ -z "${name}" ]] && continue
    if [[ "${status}" == *"(healthy)"* ]] || { [[ "${status}" == "Up "* ]] && [[ "${status}" != *"(unhealthy)"* ]]; }; then
      continue
    fi
    echo "" >&2
    log "── logs: ${name} (${status}) ──"
    if (( use_sg )); then
      sg docker -c "docker logs --tail=80 '${name}' 2>&1" >&2 || true
    else
      docker logs --tail=80 "${name}" >&2 2>&1 || true
    fi
  done <<<"${listing}"
}

# Activate docker group for caller's shell when usermod just added them.
# usermod -aG only takes effect on next login session, so the user's current
# shell still hits "permission denied while trying to connect to the docker
# API at unix:///var/run/docker.sock". Offer to drop them into a subshell
# (`exec sg docker`) that has the group, or print activation instructions.
finalize_docker_access() {
  [[ "${OS_KIND}" == "linux" ]] || return 0
  [[ "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] || return 0
  command -v sg >/dev/null 2>&1 || {
    warn "'sg' not available — log out/in to activate docker group"
    return 0
  }

  echo "" >&2
  warn "Current shell lacks 'docker' supplementary group."
  warn "Plain 'docker ps' will fail with: permission denied on /var/run/docker.sock"
  echo "" >&2
  echo "${c_b}── Activate docker group ──${c_reset}" >&2
  echo "   1) Spawn subshell with docker group  ${c_y}(recommended)${c_reset}" >&2
  echo "      → ${c_g}exec sg docker -c \"\$SHELL\"${c_reset}" >&2
  echo "   2) Print instructions only (no shell change)" >&2
  echo "   3) Do nothing" >&2

  local pick
  read -r -p "Selection [1]: " pick
  case "${pick:-1}" in
    1|"")
      log "Spawning subshell: sg docker -c \"${SHELL:-/bin/bash}\""
      exec sg docker -c "${SHELL:-/bin/bash}"
      ;;
    2)
      echo "" >&2
      echo "Run ONE of these in your current terminal:" >&2
      echo "  ${c_g}newgrp docker${c_reset}                  # activate group in this shell" >&2
      echo "  ${c_g}exec sg docker -c \"\$SHELL\"${c_reset}    # spawn subshell with group" >&2
      echo "  log out and log back in           # permanent fix" >&2
      ;;
    *) ;;
  esac
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  log "Dist-Standard-Service: workspace=${WORKSPACE_DIR}, repos=${#INPUT_REPOS[@]}"
  detect_os
  bootstrap_tools
  sync_all_repos
  resolve_ops_dir
  load_compose_files
  generate_makefile
  run_user_commands
  choose_and_run
  finalize_docker_access
  ok "Done."
}

main "$@"
