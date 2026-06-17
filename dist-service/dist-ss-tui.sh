#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# dist-ss-tui.sh v3.0 — Service Deployment & Distribution Shell
# Interactive REPL: autocomplete, history, repo manager, CLI mode
# ─────────────────────────────────────────────────────────────────────
set -u

# ══ ANSI ══════════════════════════════════════════════════════════════
ESC=$'\033'; CSI="${ESC}["
C_RST="${ESC}[0m"     C_BOLD="${ESC}[1m"   C_DIM="${ESC}[2m"
C_GREEN="${ESC}[32m"  C_YELLOW="${ESC}[33m" C_RED="${ESC}[31m"
C_CYAN="${ESC}[36m"   C_WHITE="${ESC}[97m"

# ══ LOG HELPERS ════════════════════════════════════════════════════════
log()   { printf '%s▶%s %s\n' "${C_CYAN}"   "${C_RST}" "$*" >&2; }
ok()    { printf '%s✓%s %s\n' "${C_GREEN}"  "${C_RST}" "$*" >&2; }
warn()  { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RST}" "$*" >&2; }
err()   { printf '%s✗%s %s\n' "${C_RED}"    "${C_RST}" "$*" >&2; }
die()   { err "$*"; cache_delete; _cleanup; exit 1; }
clog()  { log "$*"; }
cok()   { ok "$*"; }
cwarn() { warn "$*"; }
cerr()  { err "$*"; }
cprint(){ printf '%s\n' "$*"; }

# ══ STATE ══════════════════════════════════════════════════════════════
WORKSPACE_DIR="" OPS_NAME="" NO_RUN=0
AUTH_METHOD="" GITHUB_PAT="" GITHUB_USERNAME=""
declare -a INPUT_REPOS=()
declare -a SYNCED_NAMES=() COMPOSE_FILES=()
OPS_DIR="" CONF_FILE="" DEFAULT_TARGET=""
DAEMON_NEEDS_SG=0
OS_KIND="" OS_FAMILY="" PKG_MGR="" PKG_INSTALL=""
BOOTSTRAP_DONE=0
_PAT_CRED_FILE=""

# ══ CACHE ═════════════════════════════════════════════════════════════
_CACHE="/tmp/.dist-ss-tui-${UID}.cache"

cache_save() {
  {
    printf 'CACHE_REPOS=%q\n'        "${INPUT_REPOS[*]:-}"
    printf 'CACHE_WORKSPACE=%q\n'    "${WORKSPACE_DIR:-}"
    printf 'CACHE_OPS=%q\n'          "${OPS_NAME:-}"
    printf 'CACHE_AUTH=%q\n'         "${AUTH_METHOD:-}"
    printf 'CACHE_USER=%q\n'         "${GITHUB_USERNAME:-}"
    printf 'CACHE_TARGET=%q\n'       "${DEFAULT_TARGET:-}"
    printf 'CACHE_BOOTSTRAPPED=%q\n' "${BOOTSTRAP_DONE:-0}"
  } > "${_CACHE}"
  chmod 600 "${_CACHE}"
}

cache_load() {
  [[ -f "${_CACHE}" ]] || return 0
  local CACHE_REPOS="" CACHE_WORKSPACE="" CACHE_OPS=""
  local CACHE_AUTH="" CACHE_USER="" CACHE_TARGET="" CACHE_BOOTSTRAPPED=""
  # shellcheck disable=SC1090
  . "${_CACHE}"
  [[ -n "${CACHE_REPOS}" ]]        && read -r -a INPUT_REPOS <<< "${CACHE_REPOS}" || true
  [[ -n "${CACHE_WORKSPACE}" ]]    && WORKSPACE_DIR="${CACHE_WORKSPACE}"
  [[ -n "${CACHE_OPS}" ]]          && OPS_NAME="${CACHE_OPS}"
  [[ -n "${CACHE_AUTH}" ]]         && AUTH_METHOD="${CACHE_AUTH}"
  [[ -n "${CACHE_USER}" ]]         && GITHUB_USERNAME="${CACHE_USER}"
  [[ -n "${CACHE_TARGET}" ]]       && DEFAULT_TARGET="${CACHE_TARGET}"
  [[ -n "${CACHE_BOOTSTRAPPED}" ]] && BOOTSTRAP_DONE="${CACHE_BOOTSTRAPPED}"
}

cache_delete() { rm -f "${_CACHE}" 2>/dev/null || true; }

# ══ TRAPS ══════════════════════════════════════════════════════════════
_cleanup() {
  [[ -n "${_PAT_CRED_FILE:-}" ]] && rm -f "${_PAT_CRED_FILE}" 2>/dev/null || true
  stty sane 2>/dev/null || true
}
trap '_cleanup' EXIT TERM HUP

_INT_LAST=0
_int_handler() {
  local now="${SECONDS}"
  if (( now - _INT_LAST <= 2 )); then cache_delete; _cleanup; exit 130; fi
  _INT_LAST="${now}"
  printf '\n%s!%s Press Ctrl+C again within 2 seconds to exit (clears cache)\n' "${C_YELLOW}" "${C_RST}"
}
trap '_int_handler' INT

# ══ MENU (inline, no alt-buffer) ══════════════════════════════════════
MENU_IDX=0

run_menu() {
  local title="$1" sel="$2"; shift 2
  local -a items=("$@"); local count="${#items[@]}"
  local total_lines=$(( count + 1 ))

  printf '  %s%s%s\n' "${C_BOLD}" "${title}" "${C_RST}"
  local i
  for (( i=0; i<count; i++ )); do
    (( i == sel )) \
      && printf '  %s▶ %s%s\n' "${C_GREEN}${C_BOLD}" "${items[$i]}" "${C_RST}" \
      || printf '    %s\n' "${items[$i]}"
  done

  local old_stty; old_stty=$(stty -g 2>/dev/null)
  stty -echo -icanon min 1 time 0 2>/dev/null || true

  while true; do
    local char="" key=""
    IFS= read -r -s -n1 char 2>/dev/null || char=""
    if [[ "${char}" == $'\x1b' ]]; then
      local c1="" c2=""
      stty -echo -icanon min 0 time 1 2>/dev/null || true
      IFS= read -r -s -n1 c1 2>/dev/null || c1=""
      if [[ "${c1}" == "[" || "${c1}" == "O" ]]; then
        IFS= read -r -s -n1 c2 2>/dev/null || c2=""
        case "${c2}" in A) key="UP";; B) key="DOWN";; esac
      fi
      stty -echo -icanon min 1 time 0 2>/dev/null || true
    elif [[ "${char}" == $'\n' || "${char}" == $'\r' || -z "${char}" ]]; then key="ENTER"
    elif [[ "${char}" == "q" || "${char}" == "Q" ]]; then key="ESC"
    elif [[ "${char}" == "k" ]]; then key="UP"
    elif [[ "${char}" == "j" ]]; then key="DOWN"
    fi

    case "${key}" in
      UP)   sel=$(( (sel-1+count) % count )) ;;
      DOWN) sel=$(( (sel+1) % count )) ;;
      ENTER)
        printf '\033[%dA' "${total_lines}"; printf '\033[J'
        printf '  %s%s:%s %s\n' "${C_BOLD}" "${title}" "${C_RST}" "${items[$sel]}"
        MENU_IDX="${sel}"
        stty "${old_stty}" 2>/dev/null || true
        return 0 ;;
      ESC)
        printf '\033[%dA' "${total_lines}"; printf '\033[J'
        MENU_IDX=-1
        stty "${old_stty}" 2>/dev/null || true
        return 1 ;;
    esac

    printf '\033[%dA' "${count}"
    for (( i=0; i<count; i++ )); do
      printf '\r\033[K'
      (( i == sel )) \
        && printf '  %s▶ %s%s\n' "${C_GREEN}${C_BOLD}" "${items[$i]}" "${C_RST}" \
        || printf '    %s\n' "${items[$i]}"
    done
  done
}

# ══ INPUT ══════════════════════════════════════════════════════════════
cinput() {
  local prompt="$1" varname="$2" opt="${3:-}"
  printf '%s%s%s ' "${C_CYAN}${C_BOLD}" "${prompt}" "${C_RST}"
  local val=""
  if [[ "${opt}" == "secret" ]]; then
    stty -echo 2>/dev/null || true
    IFS= read -r val 2>/dev/null || val=""
    stty echo 2>/dev/null || true
    printf '\n'
  else
    IFS= read -r val 2>/dev/null || val=""
  fi
  val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
  printf -v "${varname}" '%s' "${val}"
}

# ══ REPL HISTORY ═══════════════════════════════════════════════════════
declare -a REPL_HISTORY=()
REPL_HIST_FILE="/tmp/.dist-ss-tui_history"
REPL_READ_RESULT=""

load_history() {
  [[ -f "${REPL_HIST_FILE}" ]] || return 0
  while IFS= read -r line; do
    [[ -n "${line}" ]] && REPL_HISTORY+=("${line}")
  done < "${REPL_HIST_FILE}"
}

save_history() {
  printf '' > "${REPL_HIST_FILE}"
  local h
  for h in "${REPL_HISTORY[@]:-}"; do
    [[ -n "${h}" ]] && printf '%s\n' "${h}" >> "${REPL_HIST_FILE}"
  done
}

# ══ REPL LINE EDITOR (autocomplete + history + cursor) ════════════════
repl_read() {
  local buffer="" cursor=0
  local hist_pos=${#REPL_HISTORY[@]}
  local prompt="${C_BOLD}${C_GREEN}>    ${C_RST}"
  local menu_sel=0 menu_closed=0

  local old_stty; old_stty=$(stty -g 2>/dev/null)
  stty -echo -icanon min 1 time 0 2>/dev/null || true

  local -a all_commands=(
    "/repo" "/workspace" "/auth" "/bootstrap" "/status" "/dist-run" "/help" "/exit"
  )

  while true; do
    local -a filtered_items=()
    local menu_active=0

    if (( ! menu_closed )) && [[ "${buffer}" == /* && "${buffer}" != *" "* ]]; then
      local cmd
      for cmd in "${all_commands[@]}"; do
        [[ "${cmd}" == "${buffer}"* ]] && filtered_items+=("${cmd}")
      done
      if (( ${#filtered_items[@]} > 0 )); then
        menu_active=1
        (( menu_sel >= ${#filtered_items[@]} )) && menu_sel=0
        (( menu_sel < 0 )) && menu_sel=$(( ${#filtered_items[@]} - 1 ))
      fi
    fi

    local menu_lines=0
    printf '\r\033[J'
    printf '%s%s' "${prompt}" "${buffer}"
    if (( menu_active )); then
      printf '\n  %sAutocomplete Command%s' "${C_BOLD}" "${C_RST}"
      menu_lines=1
      local i
      for (( i=0; i<${#filtered_items[@]}; i++ )); do
        (( i == menu_sel )) \
          && printf '\n  %s▶ %s%s' "${C_GREEN}${C_BOLD}" "${filtered_items[$i]}" "${C_RST}" \
          || printf '\n    %s' "${filtered_items[$i]}"
        (( menu_lines++ ))
      done
    fi
    (( menu_lines > 0 )) && printf '\033[%dA' "${menu_lines}"
    printf '\r%s%s' "${prompt}" "${buffer:0:$cursor}"

    local char=""
    IFS= read -r -s -n1 char 2>/dev/null || char=""

    if [[ "${char}" == $'\x1b' ]]; then
      local n1="" n2=""
      stty -echo -icanon min 0 time 1 2>/dev/null || true
      IFS= read -r -s -n1 n1 2>/dev/null || n1=""
      if [[ -z "${n1}" ]]; then
        menu_closed=1
      elif [[ "${n1}" == "[" || "${n1}" == "O" ]]; then
        IFS= read -r -s -n1 n2 2>/dev/null || n2=""
        case "${n2}" in
          A) # UP
            if (( menu_active )); then (( menu_sel-- ))
            elif (( hist_pos > 0 )); then
              (( hist_pos-- )); buffer="${REPL_HISTORY[$hist_pos]}"; cursor=${#buffer}
            fi ;;
          B) # DOWN
            if (( menu_active )); then (( menu_sel++ ))
            elif (( hist_pos < ${#REPL_HISTORY[@]} )); then
              (( hist_pos++ ))
              if (( hist_pos == ${#REPL_HISTORY[@]} )); then buffer=""
              else buffer="${REPL_HISTORY[$hist_pos]}"; fi
              cursor=${#buffer}
            fi ;;
          C) (( cursor < ${#buffer} )) && (( cursor++ )) ;;
          D) (( cursor > 0 )) && (( cursor-- )) ;;
          3)
            local n3=""; IFS= read -r -s -n1 n3 2>/dev/null || n3=""
            [[ "${n3}" == "~" && $cursor -lt ${#buffer} ]] \
              && buffer="${buffer:0:$cursor}${buffer:$((cursor+1))}" ;;
        esac
      fi
      stty -echo -icanon min 1 time 0 2>/dev/null || true
    elif [[ -z "${char}" ]]; then
      if (( menu_active )); then
        buffer="${filtered_items[$menu_sel]} "; cursor=${#buffer}; menu_closed=0
      else
        printf '\n'
        stty "${old_stty}" 2>/dev/null || true
        if [[ -n "${buffer}" ]]; then
          local last_idx=$(( ${#REPL_HISTORY[@]} - 1 ))
          if (( last_idx < 0 )) || [[ "${REPL_HISTORY[$last_idx]}" != "${buffer}" ]]; then
            REPL_HISTORY+=("${buffer}"); save_history
          fi
        fi
        REPL_READ_RESULT="${buffer}"
        return 0
      fi
    elif [[ "${char}" == $'\x7f' || "${char}" == $'\x08' ]]; then
      if (( cursor > 0 )); then
        buffer="${buffer:0:$((cursor-1))}${buffer:$cursor}"; (( cursor-- ))
      fi
      menu_closed=0
    else
      local ascii_val; ascii_val=$(printf '%d' "'${char}" 2>/dev/null || echo 0)
      if (( ascii_val >= 32 && ascii_val <= 126 )); then
        buffer="${buffer:0:$cursor}${char}${buffer:$cursor}"; (( cursor++ )); menu_closed=0
      fi
    fi
  done
}

# ══ REPO REORDER ═══════════════════════════════════════════════════════
move_item_loop() {
  local ref_list_name="$1" idx="$2"
  eval "local -a list=(\"\${${ref_list_name}[@]}\")"
  local count="${#list[@]}" total_lines=$(( count + 2 ))

  while true; do
    printf '  %sMove item [↑/↓] Enter to lock, ESC to cancel:%s\n' "${C_BOLD}" "${C_RST}"
    local i
    for (( i=0; i<count; i++ )); do
      (( i == idx )) \
        && printf '  %s⇄ %d) %s%s\n' "${C_YELLOW}${C_BOLD}" $((i+1)) "${list[$i]}" "${C_RST}" \
        || printf '    %d) %s\n' $((i+1)) "${list[$i]}"
    done
    printf '    Done\n'

    local char="" key=""
    IFS= read -r -s -n1 char 2>/dev/null || char=""
    if [[ "${char}" == $'\x1b' ]]; then
      local n1="" n2=""
      stty -echo -icanon min 0 time 1 2>/dev/null || true
      IFS= read -r -s -n1 n1 2>/dev/null || n1=""
      [[ "${n1}" == "[" || "${n1}" == "O" ]] && {
        IFS= read -r -s -n1 n2 2>/dev/null || n2=""
        case "${n2}" in A) key="UP";; B) key="DOWN";; esac
      }
      stty -echo -icanon min 1 time 0 2>/dev/null || true
    elif [[ "${char}" == $'\n' || "${char}" == $'\r' || -z "${char}" ]]; then key="ENTER"
    elif [[ "${char}" == "q" || "${char}" == "Q" ]]; then key="ESC"
    elif [[ "${char}" == "k" ]]; then key="UP"
    elif [[ "${char}" == "j" ]]; then key="DOWN"
    fi

    if [[ "${key}" == "UP" ]] && (( idx > 0 )); then
      local tmp="${list[$idx]}"; list[$idx]="${list[$((idx-1))]}"; list[$((idx-1))]="${tmp}"; (( idx-- ))
    elif [[ "${key}" == "DOWN" ]] && (( idx < count-1 )); then
      local tmp="${list[$idx]}"; list[$idx]="${list[$((idx+1))]}"; list[$((idx+1))]="${tmp}"; (( idx++ ))
    elif [[ "${key}" == "ENTER" || "${key}" == "ESC" ]]; then
      printf '\033[%dA' "${total_lines}"; printf '\033[J'
      eval "${ref_list_name}=(\"\${list[@]}\")"; return 0
    fi
    printf '\033[%dA' "$((total_lines-1))"
  done
}

reorder_repos_ui() {
  local ref_name="$1"
  eval "local -a list=(\"\${${ref_name}[@]}\")"
  local count="${#list[@]}" sel=0
  local total_lines=$(( count + 2 ))

  local old_stty; old_stty=$(stty -g 2>/dev/null)
  stty -echo -icanon min 1 time 0 2>/dev/null || true

  while true; do
    printf '  %sSelect repo to move, or Done:%s\n' "${C_BOLD}" "${C_RST}"
    local i
    for (( i=0; i<count; i++ )); do
      (( i == sel )) \
        && printf '  %s▶ %d) %s%s\n' "${C_GREEN}${C_BOLD}" $((i+1)) "${list[$i]}" "${C_RST}" \
        || printf '    %d) %s\n' $((i+1)) "${list[$i]}"
    done
    (( sel == count )) \
      && printf '  %s▶ Done%s\n' "${C_GREEN}${C_BOLD}" "${C_RST}" \
      || printf '    Done\n'

    local char="" key=""
    IFS= read -r -s -n1 char 2>/dev/null || char=""
    if [[ "${char}" == $'\x1b' ]]; then
      local n1="" n2=""
      stty -echo -icanon min 0 time 1 2>/dev/null || true
      IFS= read -r -s -n1 n1 2>/dev/null || n1=""
      [[ "${n1}" == "[" || "${n1}" == "O" ]] && {
        IFS= read -r -s -n1 n2 2>/dev/null || n2=""
        case "${n2}" in A) key="UP";; B) key="DOWN";; esac
      }
      stty -echo -icanon min 1 time 0 2>/dev/null || true
    elif [[ "${char}" == $'\n' || "${char}" == $'\r' || -z "${char}" ]]; then key="ENTER"
    elif [[ "${char}" == "q" || "${char}" == "Q" ]]; then key="ESC"
    elif [[ "${char}" == "k" ]]; then key="UP"
    elif [[ "${char}" == "j" ]]; then key="DOWN"
    fi

    case "${key}" in
      UP)   sel=$(( (sel-1+count+1) % (count+1) )) ;;
      DOWN) sel=$(( (sel+1) % (count+1) )) ;;
      ENTER)
        if (( sel == count )); then
          printf '\033[%dA' "${total_lines}"; printf '\033[J'
          stty "${old_stty}" 2>/dev/null || true
          eval "${ref_name}=(\"\${list[@]}\")"; return 0
        else
          printf '\033[%dA' "${total_lines}"; printf '\033[J'
          move_item_loop list "${sel}"
          stty -echo -icanon min 1 time 0 2>/dev/null || true
        fi ;;
      ESC)
        printf '\033[%dA' "${total_lines}"; printf '\033[J'
        stty "${old_stty}" 2>/dev/null || true
        eval "${ref_name}=(\"\${list[@]}\")"; return 0 ;;
    esac
    printf '\033[%dA' "$((total_lines-1))"
  done
}

# ══ OS / TOOLING ════════════════════════════════════════════════════════
detect_os() {
  OS_KIND=""; OS_FAMILY=""; PKG_MGR=""; PKG_INSTALL=""
  case "$(uname -s)" in
    Darwin)
      OS_KIND="macos"
      if command -v brew >/dev/null 2>&1; then PKG_MGR="brew"; PKG_INSTALL="brew install"
      else warn "Homebrew not found — install from https://brew.sh"; fi ;;
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
            command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf" || PKG_MGR="yum"
            PKG_INSTALL="sudo ${PKG_MGR} install -y" ;;
          *arch*)
            OS_FAMILY="arch"; PKG_MGR="pacman"
            PKG_INSTALL="sudo pacman -S --noconfirm" ;;
          *) OS_FAMILY="unknown" ;;
        esac
      fi ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
  ok "OS: ${OS_KIND} (${OS_FAMILY:-unknown}), pkg=${PKG_MGR:-none}"
}

install_pkg() {
  local pkg="$1"
  [[ -n "${PKG_INSTALL}" ]] || die "No package manager — install ${pkg} manually."
  clog "Installing ${pkg}…"
  local tmpf; tmpf="$(mktemp)"; local rc=0
  # shellcheck disable=SC2086
  eval "${PKG_INSTALL} ${pkg}" >"${tmpf}" 2>&1 || rc=$?
  rm -f "${tmpf}"
  (( rc != 0 )) && die "Failed to install ${pkg} (rc=${rc})"
  cok "Installed: ${pkg}"
}

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "${cmd}" >/dev/null 2>&1 && { ok "${cmd}: OK"; return; }
  warn "${cmd} missing — installing"; install_pkg "${pkg}"
  command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} still missing after install"
}

repair_apt_gh_keyring() {
  [[ "${OS_FAMILY}" == "debian" ]] || return 0
  local out; out="$(sudo apt-get update 2>&1 || true)"
  grep -qE 'NO_PUBKEY[[:space:]]+23F3D4EA75716059|cli\.github\.com.*not signed' <<<"${out}" || return 0
  warn "GitHub CLI APT keyring broken — repairing"
  sudo mkdir -p /etc/apt/keyrings
  if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null 2>&1; then
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    if sudo apt-get update -y 2>&1 | grep -qE 'NO_PUBKEY|not signed'; then
      warn "Keyring fix failed — disabling gh APT repo"
      sudo rm -f /etc/apt/sources.list.d/github-cli.list \
                 /etc/apt/keyrings/githubcli-archive-keyring.gpg
      sudo apt-get update -y >/dev/null 2>&1
    else ok "GitHub CLI keyring restored"; fi
  fi
}

install_docker_debian() {
  clog "Installing Docker via official APT repo"
  sudo apt-get install -y ca-certificates curl gnupg >/dev/null 2>&1
  sudo install -m 0755 -d /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  local distro codename arch
  distro="$(. /etc/os-release && echo "${ID}")"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  arch="$(dpkg --print-architecture)"
  [[ "${distro}" == "ubuntu" || "${distro}" == "debian" ]] || distro="ubuntu"
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} ${codename} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y >/dev/null 2>&1
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
}

install_docker_rhel() {
  clog "Installing Docker via official ${PKG_MGR} repo"
  sudo "${PKG_MGR}" remove -y podman-docker >/dev/null 2>&1 || true
  command -v dnf >/dev/null 2>&1 \
    && sudo dnf install -y dnf-plugins-core >/dev/null 2>&1 \
    || sudo yum install -y yum-utils >/dev/null 2>&1
  local repo_distro
  case "$(. /etc/os-release && echo "${ID}")" in
    fedora) repo_distro="fedora" ;; rhel) repo_distro="rhel" ;; *) repo_distro="centos" ;;
  esac
  local repo_url="https://download.docker.com/linux/${repo_distro}/docker-ce.repo"
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf config-manager --add-repo "${repo_url}" >/dev/null 2>&1 \
      || sudo dnf config-manager addrepo --from-repofile="${repo_url}" >/dev/null 2>&1
  else sudo yum-config-manager --add-repo "${repo_url}" >/dev/null 2>&1; fi
  sudo "${PKG_MGR}" install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "docker missing — installing"
    case "${OS_KIND}" in
      macos) install_pkg "--cask docker" ;;
      linux)
        case "${OS_FAMILY}" in
          debian) repair_apt_gh_keyring; install_docker_debian ;;
          fedora) install_docker_rhel ;;
          arch)   install_pkg "docker docker-compose" ;;
          *)      die "Unsupported Linux family: ${OS_FAMILY}" ;;
        esac ;;
      *) die "Unsupported OS for docker: ${OS_KIND}" ;;
    esac
    command -v docker >/dev/null 2>&1 || die "docker install failed"
  fi
  ok "docker: OK"

  DAEMON_NEEDS_SG=0
  if docker info >/dev/null 2>&1; then
    ok "docker daemon: running"
  elif sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then
    warn "Docker daemon OK but socket not accessible yet (docker group pending)"
    DAEMON_NEEDS_SG=1
  else
    case "${OS_KIND}" in
      linux)
        clog "Starting docker daemon"
        sudo systemctl enable --now docker >/dev/null 2>&1 || die "Failed to start docker" ;;
      macos)
        warn "Docker not running — launching Docker.app"
        open -ga Docker 2>/dev/null || true
        clog "Waiting up to 60s for docker daemon…"
        local i; for i in {1..30}; do docker info >/dev/null 2>&1 && break; sleep 2; done ;;
    esac
    docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1 \
      || die "docker daemon offline"
    ok "docker daemon: running"
  fi

  if [[ "${OS_KIND}" == "linux" ]]; then
    local me="${USER:-$(id -un)}"
    if ! getent group docker 2>/dev/null | grep -qE "(:|,)${me}(,|\$)"; then
      clog "Adding ${me} to docker group"
      sudo usermod -aG docker "${me}" 2>/dev/null || warn "usermod failed"
    fi
    if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      ok "docker group: active"; DAEMON_NEEDS_SG=0
    else
      warn "docker group not active in current shell — using sg docker -c"; DAEMON_NEEDS_SG=1
    fi
  fi
  export DAEMON_NEEDS_SG

  if ! docker compose version >/dev/null 2>&1; then
    clog "docker compose v2 missing — installing"
    case "${OS_FAMILY}" in
      debian) repair_apt_gh_keyring; install_docker_debian ;;
      fedora) install_docker_rhel ;;
      arch)   install_pkg "docker-compose" ;;
      *)      warn "Install docker compose v2 manually for ${OS_KIND}" ;;
    esac
    docker compose version >/dev/null 2>&1 || die "docker compose v2 still missing"
  fi
  ok "docker compose: OK"
}

ensure_make() {
  command -v make >/dev/null 2>&1 && { ok "make: OK"; return; }
  log "make missing — installing"; install_pkg make
  command -v make >/dev/null 2>&1 || die "make install failed"
}

install_node_debian() {
  clog "Installing Node.js 20 LTS via NodeSource (Debian/Ubuntu)"
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
}

install_node_rhel() {
  clog "Installing Node.js 20 LTS via NodeSource (RHEL/Fedora)"
  curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo -E bash -
  sudo "${PKG_MGR}" install -y nodejs
}

ensure_node() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    ok "node: $(node --version), npm: $(npm --version)"; return
  fi
  clog "Node.js missing — installing Node.js 20 LTS"
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
  cok "node: $(node --version), npm: $(npm --version)"
}

# ══ GH AUTH ════════════════════════════════════════════════════════════
_do_gh_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh not installed — bootstrap will install it"; return 0
  fi
  if ! gh auth status >/dev/null 2>&1; then
    clog "gh not authenticated — launching gh auth login"
    gh auth login
    gh auth status >/dev/null 2>&1 || die "gh auth login failed"
  fi

  local cur; cur="$(gh api user --jq .login 2>/dev/null || echo 'unknown')"
  cok "Authenticated as: ${cur}"

  local items=("Keep current: ${cur}" "Re-login (gh auth login)" "Switch account")
  run_menu "GitHub Account" 0 "${items[@]}" || return 0

  case "${MENU_IDX}" in
    1) clog "Re-running gh auth login"; gh auth login || cwarn "gh auth login failed" ;;
    2) gh auth switch 2>/dev/null \
        || { cwarn "gh auth switch failed — running gh auth login"; gh auth login || true; } ;;
  esac

  local now; now="$(gh api user --jq .login 2>/dev/null || echo 'unknown')"
  cok "Active gh user: ${now}"
}

# ══ REPO SYNC ══════════════════════════════════════════════════════════
# URL#branch 형식 지원: URL에서 #branch 부분 추출
repo_branch_from_url() { local u="$1"; [[ "${u}" == *#* ]] && printf '%s' "${u##*#}" || printf ''; }
repo_name_from_url()   { local u="${1%%#*}"; u="${u%.git}"; basename "${u}"; }

ssh_to_https() {
  local url="${1%%#*}"  # strip #branch before converting
  [[ "${url}" =~ ^git@([^:]+):(.+)$ ]] \
    && printf 'https://%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
    || printf '%s' "${url}"
}

sync_repo() {
  local url="$1"
  local branch; branch="$(repo_branch_from_url "${url}")"
  local clean_url="${url%%#*}"
  local name; name="$(repo_name_from_url "${clean_url}")"
  local target="${WORKSPACE_DIR}/${name}"
  local -a git_opts=()
  local clone_url="${clean_url}"

  if [[ "${AUTH_METHOD}" == "pat" && -n "${_PAT_CRED_FILE}" ]]; then
    clone_url="$(ssh_to_https "${url}")"
    git_opts+=("-c" "credential.helper=store --file=${_PAT_CRED_FILE}")
  fi

  local tmpf; tmpf="$(mktemp)"; local rc=0

  if [[ -d "${target}/.git" ]]; then
    clog "Pulling ${name}…"
    local cur_branch; cur_branch="${branch:-$(git -C "${target}" symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)}"
    git ${git_opts+"${git_opts[@]}"} -C "${target}" fetch --all --prune >"${tmpf}" 2>&1 || true
    git ${git_opts+"${git_opts[@]}"} -C "${target}" pull --ff-only origin "${cur_branch}" >>"${tmpf}" 2>&1 || rc=$?
    (( rc == 0 )) && cok "Pulled: ${name}${branch:+ (${branch})}" || cwarn "${name}: pull skipped (rc=${rc})"
  elif [[ -e "${target}" ]]; then
    cwarn "${target} exists but not a git repo — skipping"
  else
    clog "Cloning ${name}${branch:+ (branch: ${branch})}…"
    local -a clone_args=()
    [[ -n "${branch}" ]] && clone_args+=("--branch" "${branch}")
    git ${git_opts+"${git_opts[@]}"} clone "${clone_args[@]+"${clone_args[@]}"}" "${clone_url}" "${target}" >"${tmpf}" 2>&1 || rc=$?
    if (( rc != 0 )); then
      cerr "Clone failed: ${name}"
      while IFS= read -r line; do cwarn "  ${line}"; done < "${tmpf}"
      rm -f "${tmpf}"; die "Clone failed for ${name}"
    fi
    cok "Cloned: ${name}${branch:+ (${branch})}"
  fi
  rm -f "${tmpf}"
  printf '%s\n' "${name}"
}

sync_all_repos() {
  clog "Workspace: ${WORKSPACE_DIR}"
  SYNCED_NAMES=()
  local url name
  for url in "${INPUT_REPOS[@]}"; do
    name="$(sync_repo "${url}")"
    SYNCED_NAMES+=("${name}")
  done
  ok "Synced: ${SYNCED_NAMES[*]}"
}

# ══ COMPOSE / OPS ══════════════════════════════════════════════════════
find_compose_files() {
  find "$1" \
    \( -name .git -o -name node_modules -o -name vendor -o -name dist \
       -o -name build -o -name .venv -o -name venv -o -name __pycache__ \) -prune -o \
    -maxdepth 6 -type f \
    \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
       -o -name 'compose.yml' -o -name 'compose.yaml' \) \
    -print 2>/dev/null
}

resolve_ops_dir() {
  if [[ -z "${OPS_NAME}" ]]; then
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
  ok "Ops project: ${OPS_NAME}"
}

load_compose_files() {
  COMPOSE_FILES=()
  if [[ -f "${OPS_DIR}/Makefile" ]]; then ok "Makefile present"; return; fi
  local abs rel
  while IFS= read -r abs; do
    [[ -z "${abs}" ]] && continue
    rel="${abs#${OPS_DIR}/}"; COMPOSE_FILES+=("${rel}")
  done < <(find_compose_files "${OPS_DIR}" | sort)
  if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
    warn "No docker-compose*.yml under ${OPS_DIR} — deployment skipped"
    NO_RUN=1; return
  fi
  log "Compose files: ${COMPOSE_FILES[*]}"
}

generate_makefile() {
  local mk="${OPS_DIR}/Makefile"
  [[ -f "${mk}" ]] && { ok "Makefile present"; return; }
  [[ ${#COMPOSE_FILES[@]} -gt 0 ]] || return
  warn "Makefile missing — generating"

  local base="" f bn shallowest=99 depth
  for f in "${COMPOSE_FILES[@]}"; do
    bn="$(basename "${f}")"
    if [[ "${bn}" == "docker-compose.yml" || "${bn}" == "compose.yml" \
       || "${bn}" == "docker-compose.yaml" || "${bn}" == "compose.yaml" ]]; then
      depth="$(awk -F/ '{print NF}' <<<"${f}")"
      (( depth < shallowest )) && { shallowest="${depth}"; base="${f}"; }
    fi
  done

  {
    echo "SHELL := /bin/bash"
    echo "# Auto-generated by dist-ss-tui.sh"
    echo ""
    local flags=""; [[ -n "${base}" ]] && flags="-f ${base}"
    echo ".PHONY: help up down ps logs build clean"
    echo ""
    echo "help:"
    echo -e "\t@grep -E '^[a-zA-Z0-9_-]+:.*?## ' \$(MAKEFILE_LIST) | awk 'BEGIN{FS=\":.*?## \"};{printf \"  %-30s %s\\n\", \$\$1, \$\$2}'"
    echo ""
    local dir tag dtag
    for f in "${COMPOSE_FILES[@]}"; do
      [[ "${f}" == "${base}" ]] && continue
      bn="$(basename "${f}")"; dir="$(dirname "${f}")"
      tag="${bn%.yml}"; tag="${tag%.yaml}"
      tag="${tag#docker-compose.}"; tag="${tag#docker-compose}"
      tag="${tag#compose.}"; tag="${tag#compose}"
      if [[ "${dir}" != "." ]]; then
        dtag="${dir//\//-}"
        [[ -n "${tag}" ]] && tag="${dtag}-${tag}" || tag="${dtag}"
      fi
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
      echo "ps:"; echo -e "\tdocker compose ${flags} ps"
      echo "logs:"; echo -e "\tdocker compose ${flags} logs -f --tail=200"
      echo "build:"; echo -e "\tdocker compose ${flags} build"
      echo "clean:"; echo -e "\tdocker compose ${flags} down -v --remove-orphans"
    fi
  } > "${mk}"
  ok "Generated Makefile"
}

list_make_up_targets() {
  local mk="${OPS_DIR}/Makefile"; [[ -f "${mk}" ]] || return
  local all up_only
  all="$(awk -F: '/^[A-Za-z0-9_.\/-]+[ \t]*:/{name=$1;sub(/[ \t]+$/,"",name);if(name~/^\./||name=="help"||name=="list-targets")next;print name}' "${mk}" | sort -u)"
  up_only="$(grep -E '^up(-|$)' <<<"${all}" || true)"
  [[ -n "${up_only}" ]] && printf '%s\n' "${up_only}" || printf '%s\n' "${all}"
}

load_default() {
  [[ -f "${CONF_FILE:-}" ]] || { DEFAULT_TARGET=""; return; }
  # shellcheck disable=SC1090
  . "${CONF_FILE}"; DEFAULT_TARGET="${LAST_TARGET:-}"
}

save_default() {
  [[ -n "${CONF_FILE:-}" ]] || return 0
  printf 'LAST_TARGET=%q\nLAST_RUN=%q\n' "$1" "$(date -u +%FT%TZ)" > "${CONF_FILE}"
}

dump_unhealthy_logs() {
  cwarn "Collecting logs from unhealthy containers…"
  local use_sg=0
  [[ "${OS_KIND}" == "linux" && "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] \
    && command -v sg >/dev/null 2>&1 && use_sg=1

  local listing
  (( use_sg )) \
    && listing="$(sg docker -c 'docker ps -a --format "{{.Names}}\t{{.Status}}"' 2>/dev/null || true)" \
    || listing="$(docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null || true)"
  [[ -n "${listing}" ]] || { cwarn "No containers found"; return; }

  while IFS=$'\t' read -r name status; do
    [[ -z "${name}" ]] && continue
    [[ "${status}" == *"(healthy)"* ]] && continue
    { [[ "${status}" == "Up "* ]] && [[ "${status}" != *"(unhealthy)"* ]]; } && continue
    clog "── ${name} (${status}) ──"
    local logs
    (( use_sg )) \
      && logs="$(sg docker -c "docker logs --tail=40 '${name}' 2>&1" || true)" \
      || logs="$(docker logs --tail=40 "${name}" 2>&1 || true)"
    while IFS= read -r line; do cprint "${C_DIM}  ${line}${C_RST}"; done <<< "${logs}"
  done <<< "${listing}"
}

_finalize_docker_access() {
  [[ "${OS_KIND}" == "linux" ]] || return 0
  [[ "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] || return 0
  command -v sg >/dev/null 2>&1 || { warn "'sg' not available — log out/in to activate docker group"; return 0; }

  local items=("sg docker 서브셸 실행 (권장)" "활성화 방법 안내" "건너뜀")
  run_menu "Docker Group 활성화" 0 "${items[@]}" || return 0

  case "${MENU_IDX}" in
    0) exec sg docker -c "${SHELL:-/bin/bash}" ;;
    1)
      printf '\n현재 터미널에서 아래 중 하나를 실행하세요:\n'
      printf '  %snewgrp docker%s\n' "${C_GREEN}" "${C_RST}"
      printf '  %sexec sg docker -c "$SHELL"%s\n' "${C_GREEN}" "${C_RST}"
      printf '  로그아웃 후 재로그인\n\n' ;;
  esac
}

# ══ COMMAND HANDLERS ══════════════════════════════════════════════════

handle_repo() {
  if [[ $# -gt 0 ]]; then
    INPUT_REPOS=("$@")
    cok "Repositories updated: ${INPUT_REPOS[*]}"
    cache_save; return
  fi

  local -a temp_repos=("${INPUT_REPOS[@]:-}")
  while true; do
    printf '\n%s━━ Repository Manager ━━%s\n' "${C_BOLD}" "${C_RST}"
    if [[ ${#temp_repos[@]} -eq 0 ]]; then
      printf '  %s(No repositories registered)%s\n' "${C_DIM}" "${C_RST}"
    else
      local i
      for (( i=0; i<${#temp_repos[@]}; i++ )); do
        printf '  %d) %s\n' $((i+1)) "${temp_repos[$i]}"
      done
    fi
    printf '\n'

    local -a menu_items=("Add Repository")
    [[ ${#temp_repos[@]} -gt 0 ]] && menu_items+=("Delete Repository" "Clear All")
    [[ ${#temp_repos[@]} -gt 1 ]] && menu_items+=("Change Order (Reorder)")
    menu_items+=("Save & Exit" "Cancel & Discard")

    run_menu "Actions" 0 "${menu_items[@]}"
    [[ "${MENU_IDX}" -eq -1 ]] && { cwarn "Discarded changes."; return 0; }
    local action="${menu_items[${MENU_IDX}]}"

    case "${action}" in
      "Add Repository")
        if [[ ${#temp_repos[@]} -ge 8 ]]; then cwarn "Maximum 8 repositories."; continue; fi
        local url=""
        cinput "Enter Repo URL:" url
        [[ -n "${url}" ]] && { temp_repos+=("${url}"); cok "Added: ${url}"; }
        ;;
      "Delete Repository")
        run_menu "Select Repository to Delete" 0 "${temp_repos[@]}"
        if (( MENU_IDX >= 0 )); then
          local deleted="${temp_repos[${MENU_IDX}]}"
          local -a next=()
          local i
          for (( i=0; i<${#temp_repos[@]}; i++ )); do
            (( i != MENU_IDX )) && next+=("${temp_repos[$i]}")
          done
          temp_repos=("${next[@]:-}")
          cok "Deleted: ${deleted}"
        fi
        ;;
      "Clear All")
        run_menu "Are you sure?" 1 "Yes, Clear All" "No, Keep Them"
        (( MENU_IDX == 0 )) && { temp_repos=(); cok "Cleared."; }
        ;;
      "Change Order (Reorder)")
        reorder_repos_ui temp_repos ;;
      "Save & Exit")
        INPUT_REPOS=("${temp_repos[@]:-}")
        cok "Saved repositories."; cache_save; return 0 ;;
      "Cancel & Discard")
        cwarn "Discarded changes."; return 0 ;;
    esac
  done
}

handle_workspace() {
  if [[ $# -gt 0 ]]; then
    WORKSPACE_DIR="$1"
    mkdir -p "${WORKSPACE_DIR}"
    WORKSPACE_DIR="$(cd "${WORKSPACE_DIR}" && pwd)"
    cok "Workspace updated: ${WORKSPACE_DIR}"
    cache_save; return
  fi

  local cwd="${PWD}"
  local parent; parent="$(cd "${cwd}/.." && pwd)"
  local items=("Current dir  →  ${cwd}" "Parent dir   →  ${parent}" "Custom path...")
  run_menu "Select Clone Workspace" 0 "${items[@]}"
  case "${MENU_IDX}" in
    0) WORKSPACE_DIR="${cwd}" ;;
    1) WORKSPACE_DIR="${parent}" ;;
    2)
      local custom=""
      cinput "Custom path:" custom
      custom="${custom/#\~/$HOME}"
      WORKSPACE_DIR="${custom:-${cwd}}" ;;
    *) return ;;
  esac
  mkdir -p "${WORKSPACE_DIR}"
  WORKSPACE_DIR="$(cd "${WORKSPACE_DIR}" && pwd)"
  cok "Workspace: ${WORKSPACE_DIR}"
  cache_save
}

handle_auth() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      gh|pat|none) AUTH_METHOD="$1"; cok "Auth method: ${AUTH_METHOD}"; cache_save ;;
      *) cerr "Unknown auth method: $1. Use: gh, pat, or none" ;;
    esac
    return
  fi

  local items=(
    "gh auth login      — GitHub CLI (영구 저장, 권장)"
    "Access Token (PAT) — 1회성 Personal Access Token"
    "No auth            — 공개 저장소 전용"
  )
  run_menu "Select Auth Method" 0 "${items[@]}"
  case "${MENU_IDX}" in
    0) AUTH_METHOD="gh"   ;;
    1) AUTH_METHOD="pat"  ;;
    2) AUTH_METHOD="none" ;;
    *) return ;;
  esac
  cok "Auth method: ${AUTH_METHOD}"; cache_save

  if [[ "${AUTH_METHOD}" == "pat" ]]; then
    printf '\n'
    clog "PAT 입력 (GitHub → Settings → Developer settings → Personal access tokens)"
    cprint "${C_DIM}  최소 권한: Contents → Read-only${C_RST}"
    printf '\n'
    local _pat_empty=0
    while true; do
      cinput "GitHub Username (선택사항):" GITHUB_USERNAME
      cinput "Personal Access Token:" GITHUB_PAT "secret"
      if [[ -n "${GITHUB_PAT}" ]]; then _pat_empty=0; break; fi
      (( _pat_empty++ ))
      if (( _pat_empty >= 2 )); then
        cwarn "PAT 입력 취소 — auth 방식을 none으로 변경합니다."
        AUTH_METHOD="none"; cache_save; return 0
      fi
      cwarn "PAT가 비어있습니다. 한 번 더 빈 Enter 시 취소."
    done
    _PAT_CRED_FILE="$(mktemp)"; chmod 600 "${_PAT_CRED_FILE}"
    if [[ -n "${GITHUB_USERNAME}" ]]; then
      printf 'https://%s:%s@github.com\n' "${GITHUB_USERNAME}" "${GITHUB_PAT}" > "${_PAT_CRED_FILE}"
    else
      printf 'https://x-access-token:%s@github.com\n' "${GITHUB_PAT}" > "${_PAT_CRED_FILE}"
    fi
    cok "PAT 저장 (임시 파일, 종료 시 자동 삭제)"
    cache_save
  fi
}

handle_bootstrap() {
  printf '\n'; clog "OS 감지 및 도구 설치…"; printf '\n'
  detect_os

  if [[ "${AUTH_METHOD}" == "gh" ]]; then
    ensure_cmd git; ensure_cmd gh; _do_gh_auth
  else
    ensure_cmd git
  fi
  ensure_docker; ensure_make; ensure_node

  if [[ ${#INPUT_REPOS[@]} -eq 0 ]]; then
    cwarn "저장소가 없습니다. /repo 로 추가 후 다시 실행하세요."
    return 1
  fi

  printf '\n'; clog "저장소 동기화…"
  sync_all_repos
  resolve_ops_dir
  load_compose_files
  generate_makefile

  cok "Bootstrap 완료!"
  BOOTSTRAP_DONE=1; cache_save
}

handle_status() {
  printf '\n%s━━ dist-ss-tui Configuration Status ━━%s\n' "${C_BOLD}" "${C_RST}"

  if [[ -n "${WORKSPACE_DIR}" ]]; then
    printf '  Workspace : %s%s%s\n' "${C_GREEN}" "${WORKSPACE_DIR}" "${C_RST}"
  else
    printf '  Workspace : %s[NOT SET]%s  (/workspace 로 설정)\n' "${C_RED}" "${C_RST}"
  fi

  if [[ ${#INPUT_REPOS[@]} -gt 0 ]]; then
    printf '  Repos     : %s%s%s\n' "${C_GREEN}" "${INPUT_REPOS[*]}" "${C_RST}"
  else
    printf '  Repos     : %s[NOT SET]%s  (/repo 로 설정)\n' "${C_RED}" "${C_RST}"
  fi

  if [[ -n "${AUTH_METHOD}" ]]; then
    printf '  Auth      : %s%s%s\n' "${C_GREEN}" "${AUTH_METHOD}" "${C_RST}"
  else
    printf '  Auth      : %s[NOT SET]%s  (/auth 로 설정)\n' "${C_RED}" "${C_RST}"
  fi

  if [[ -n "${OPS_NAME}" ]]; then
    printf '  Ops Repo  : %s%s%s\n' "${C_GREEN}" "${OPS_NAME}" "${C_RST}"
  else
    printf '  Ops Repo  : %s[NOT SET]%s  (/bootstrap 시 자동 감지)\n' "${C_DIM}" "${C_RST}"
  fi

  if [[ "${BOOTSTRAP_DONE:-0}" -eq 1 ]]; then
    printf '  Bootstrap : %s[DONE]%s\n' "${C_GREEN}" "${C_RST}"
  else
    printf '  Bootstrap : %s[PENDING]%s  (/bootstrap 또는 /dist-run 실행)\n' "${C_YELLOW}" "${C_RST}"
  fi
  printf '\n'
}

handle_dist_run() {
  local missing=0
  [[ ${#INPUT_REPOS[@]} -eq 0 ]] && { cerr "저장소 없음 — /repo 로 설정하세요."; missing=1; }
  [[ -z "${WORKSPACE_DIR}" ]]    && { cerr "Workspace 없음 — /workspace 로 설정하세요."; missing=1; }
  [[ -z "${AUTH_METHOD}" ]]      && { cerr "인증 방식 없음 — /auth 로 설정하세요."; missing=1; }
  (( missing )) && return 1

  if [[ "${BOOTSTRAP_DONE:-0}" -ne 1 ]]; then
    clog "Bootstrap 미완료 — 자동 실행…"
    handle_bootstrap || { cerr "Bootstrap 실패 — 배포 중단."; return 1; }
  fi

  load_default
  local raw=()
  while IFS= read -r _t; do [[ -n "${_t}" ]] && raw+=("${_t}"); done \
    < <(list_make_up_targets)

  if [[ ${#raw[@]} -eq 0 ]]; then
    cerr "make 타겟 없음 (${OPS_DIR}/Makefile)"; return 1
  fi

  local display=() def_idx=0 i
  for (( i=0; i<${#raw[@]}; i++ )); do
    [[ "${raw[$i]}" == "${DEFAULT_TARGET}" ]] \
      && { display+=("${raw[$i]}  (last used)"); def_idx="${i}"; } \
      || display+=("${raw[$i]}")
  done
  display+=("Custom target…")

  run_menu "Make Target  [ops: ${OPS_NAME}]" "${def_idx}" "${display[@]}" || return 1

  local target=""
  if (( MENU_IDX == ${#display[@]}-1 )); then
    cinput "Custom target:" target
    [[ -z "${target}" ]] && return 1
  else
    target="${raw[${MENU_IDX}]}"
  fi
  DEFAULT_TARGET="${target}"; cache_save

  printf '\n%s━━ 실행 전 확인 ━━%s\n' "${C_BOLD}" "${C_RST}"
  printf '  Command : %s%smake %s%s\n' "${C_GREEN}" "${C_BOLD}" "${target}" "${C_RST}"
  printf '  Dir     : %s\n\n' "${OPS_DIR}"

  clog "Pre-run 명령어 (선택, 빈 Enter 2회 → 건너뜀)"
  local _pre_empty=0
  while true; do
    local ucmd=""
    cinput "Command:" ucmd
    if [[ -z "${ucmd}" ]]; then
      (( _pre_empty++ ))
      if (( _pre_empty >= 2 )); then break; fi
      cwarn "한 번 더 빈 Enter 시 건너뜀"
      continue
    fi
    _pre_empty=0
    clog "Running: ${ucmd}"
    local rc=0
    if [[ "${OS_KIND}" == "linux" && "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] && command -v sg >/dev/null 2>&1; then
      sg docker -c "cd \"${OPS_DIR}\" && ${ucmd}" || rc=$?
    else
      ( cd "${OPS_DIR}" && bash -c "${ucmd}" ) || rc=$?
    fi
    (( rc != 0 )) && cwarn "Exited ${rc}" || cok "Done"
  done

  local items=("▶ Run Now" "✗ Cancel")
  run_menu "Deploy?" 0 "${items[@]}" || return 1
  (( MENU_IDX == 1 )) && { cwarn "배포 취소."; return 1; }

  printf '\n'; clog "Running: make -C \"${OPS_DIR}\" ${target}"
  save_default "${target}"

  local tmpf; tmpf="$(mktemp)"; local exit_code=0
  if [[ "${OS_KIND}" == "linux" && "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] && command -v sg >/dev/null 2>&1; then
    sg docker -c "cd \"${OPS_DIR}\" && make ${target}" >"${tmpf}" 2>&1 || exit_code=$?
  else
    ( cd "${OPS_DIR}" && make "${target}" ) >"${tmpf}" 2>&1 || exit_code=$?
  fi
  while IFS= read -r line; do cprint "  ${line}"; done < "${tmpf}"
  rm -f "${tmpf}"

  if (( exit_code != 0 )); then
    cerr "make exited with ${exit_code}"; dump_unhealthy_logs; return "${exit_code}"
  fi
  cok "Deployment complete!"

  _finalize_docker_access
  cache_delete
  exit 0
}

# ══ WELCOME / HELP ════════════════════════════════════════════════════
print_welcome() {
  printf '\n'
  printf '  %sdist-ss-tui v3.0%s — Service Deployment & Distribution Shell\n' "${C_BOLD}${C_CYAN}" "${C_RST}"
  printf '  %sClones repos · installs tools · deploys via make · macOS · Debian · RHEL · Arch%s\n' "${C_DIM}" "${C_RST}"
  printf '  %s─────────────────────────────────────────────────────────────────────────────%s\n' "${C_DIM}" "${C_RST}"
  printf '  Commands:\n'
  printf '    %s/repo,      /R [url...]%s  저장소 URL 관리 (추가/삭제/순서변경)\n'  "${C_BOLD}" "${C_RST}"
  printf '    %s/workspace, /W [path]%s   클론 대상 디렉터리 설정\n'               "${C_BOLD}" "${C_RST}"
  printf '    %s/auth,      /A [method]%s GitHub 인증 설정 (gh|pat|none)\n'        "${C_BOLD}" "${C_RST}"
  printf '    %s/bootstrap, /B%s          도구 설치 및 저장소 동기화\n'            "${C_BOLD}" "${C_RST}"
  printf '    %s/status,    /S%s          현재 설정 상태 표시\n'                   "${C_BOLD}" "${C_RST}"
  printf '    %s/dist-run,  /D%s          설정 검증 후 make 배포 실행\n'           "${C_BOLD}" "${C_RST}"
  printf '    %s/help,      /H%s          이 도움말 표시\n'                        "${C_BOLD}" "${C_RST}"
  printf '    %s/exit,      /E%s          종료 및 캐시 삭제\n'                     "${C_BOLD}" "${C_RST}"
  printf '    %s! <command>%s             셸 명령 실행 후 결과 출력\n'             "${C_BOLD}" "${C_RST}"
  printf '  %s─────────────────────────────────────────────────────────────────────────────%s\n' "${C_DIM}" "${C_RST}"
  printf '\n'
  if [[ -f "${_CACHE}" ]]; then
    printf '  %s⚡ 이전 세션 캐시 로드됨.%s\n\n' "${C_YELLOW}" "${C_RST}"
  fi
}

# ══ TUI REPL MODE ══════════════════════════════════════════════════════
run_tui_mode() {
  cache_load; load_history; print_welcome

  local line cmd args
  while true; do
    repl_read; line="${REPL_READ_RESULT}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" ]] && continue

    if [[ "${line}" == "!"* ]]; then
      local ext_cmd="${line#!}"; ext_cmd="${ext_cmd#"${ext_cmd%%[![:space:]]*}"}"
      if [[ -z "${ext_cmd}" ]]; then cwarn "Usage: ! <command>"
      else clog "Running: ${ext_cmd}"; printf '\n'; eval "${ext_cmd}"; printf '\n'; fi
      continue
    fi

    read -r cmd args <<< "${line}"
    case "${cmd}" in
      /repo|/R)
        local -a cmd_args=(); read -r -a cmd_args <<< "${args}"
        handle_repo "${cmd_args[@]:-}" ;;
      /workspace|/W) handle_workspace ${args} ;;
      /auth|/A)      handle_auth ${args} ;;
      /bootstrap|/B) handle_bootstrap ;;
      /status|/S)    handle_status ;;
      /dist-run|/D)  handle_dist_run ;;
      /help|/H|help) print_welcome ;;
      /exit|/E)
        cok "종료. 캐시 삭제…"; cache_delete; _cleanup; exit 0 ;;
      *)
        cerr "Unknown command: ${cmd}. Type /help for available commands." ;;
    esac
  done
}

# ══ CLI (NON-INTERACTIVE) MODE ════════════════════════════════════════
run_cli_mode() {
  clog "Running dist-ss-tui in non-interactive CLI mode…"

  [[ ${#INPUT_REPOS[@]} -eq 0 ]] && die "저장소 없음 — -I/--input 으로 지정하세요."
  [[ -z "${WORKSPACE_DIR}" ]] && WORKSPACE_DIR="${PWD}"
  mkdir -p "${WORKSPACE_DIR}"
  WORKSPACE_DIR="$(cd "${WORKSPACE_DIR}" && pwd)"
  [[ -z "${AUTH_METHOD}" ]] && AUTH_METHOD="none"

  cok "Workspace: ${WORKSPACE_DIR}"
  cok "Repos: ${INPUT_REPOS[*]}"

  detect_os; ensure_cmd git
  [[ "${AUTH_METHOD}" == "gh" ]] && { ensure_cmd gh; gh auth status >/dev/null 2>&1 || die "gh CLI not logged in"; }
  ensure_docker; ensure_make; ensure_node

  clog "Syncing repositories…"
  sync_all_repos; resolve_ops_dir; load_compose_files; generate_makefile

  if [[ "${NO_RUN}" -eq 1 ]]; then warn "--no-run — skipping deployment"; exit 0; fi

  load_default
  local raw=()
  while IFS= read -r _t; do [[ -n "${_t}" ]] && raw+=("${_t}"); done < <(list_make_up_targets)
  [[ ${#raw[@]} -eq 0 ]] && { warn "No make targets — skipping"; exit 0; }

  local target=""
  [[ -n "${DEFAULT_TARGET}" ]] && target="${DEFAULT_TARGET}" || target="${raw[0]}"
  cok "Target: ${target}"

  clog "Executing: make -C \"${OPS_DIR}\" ${target}"
  local exit_code=0
  if [[ "${OS_KIND}" == "linux" && "${DAEMON_NEEDS_SG:-0}" -eq 1 ]] && command -v sg >/dev/null 2>&1; then
    sg docker -c "cd \"${OPS_DIR}\" && make ${target}" || exit_code=$?
  else
    ( cd "${OPS_DIR}" && make "${target}" ) || exit_code=$?
  fi

  if (( exit_code != 0 )); then
    cerr "Deployment failed (rc=${exit_code})"; dump_unhealthy_logs; exit "${exit_code}"
  fi
  cok "Deployment complete!"; exit 0
}

# ══ USAGE ══════════════════════════════════════════════════════════════
usage() {
  cat <<'EOF'
dist-ss-tui.sh v3.0 — Service Deployment & Distribution Shell

Usage:
  ./dist-ss-tui.sh                         # Interactive TUI REPL
  ./dist-ss-tui.sh -I "url1 url2"          # TUI with pre-filled repos
  ./dist-ss-tui.sh -I url --cli            # Non-interactive CLI deploy
  ./dist-ss-tui.sh -I url -w ~/work -o ops # TUI with pre-filled settings
  ./dist-ss-tui.sh -I url --no-run         # CLI dry-run (no deploy)

Options:
  -I, --input <repos>    공백 구분 git 저장소 URL
  -w, --workspace <dir>  워크스페이스 디렉터리
  -o, --ops <name>       ops 저장소 이름
  -c, --cli              비대화형 CLI 모드 강제
      --no-run           배포 실행 건너뜀 (CLI 모드)
  -h, --help             이 도움말

TUI 명령:
  /repo /workspace /auth /bootstrap /status /dist-run /help /exit
  ! <cmd>     셸 명령 실행
  ↑↓ 방향키  커맨드 히스토리 탐색
  / 로 시작   자동완성 메뉴

종료:
  /exit       REPL 프롬프트
  q / ESC     메뉴
  Ctrl+C × 2  강제 종료 + 캐시 삭제 (2초 이내)
EOF
}

# ══ MAIN ═══════════════════════════════════════════════════════════════
main() {
  local force_cli=0
  while (( $# )); do
    case "$1" in
      -I|--input)
        shift
        while (( $# )) && [[ "$1" != -* ]]; do
          read -r -a _tmp <<< "$1"; INPUT_REPOS+=("${_tmp[@]}"); shift
        done ;;
      -w|--workspace) WORKSPACE_DIR="$2"; shift 2 ;;
      -o|--ops)       OPS_NAME="$2"; shift 2 ;;
      --no-run)       NO_RUN=1; shift ;;
      -c|--cli)       force_cli=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) printf 'Unknown arg: %s\n' "$1" >&2; usage; exit 1 ;;
    esac
  done

  local run_tui=1
  (( NO_RUN )) || (( force_cli )) && run_tui=0

  if (( run_tui )) && [[ ! -t 0 ]]; then
    [[ -c /dev/tty ]] && exec < /dev/tty || run_tui=0
  fi

  if (( run_tui )) && [[ -t 0 ]]; then
    run_tui_mode
  else
    run_cli_mode
  fi
}

main "$@"
