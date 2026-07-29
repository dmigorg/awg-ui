#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi

  echo "ERROR: bash is required to run this installer." >&2
  exit 1
fi

set -euo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
plain='\033[0m'

AWGUI_APP_DIR="/usr/local/awg-ui"
AWGUI_COMMON="${AWGUI_APP_DIR}/awg-common.sh"
AWGUI_INSTALLER="${AWGUI_APP_DIR}/install.sh"
AWGUI_CLI_SOURCE="${AWGUI_APP_DIR}/awg-ui"
AWGUI_CLI="/usr/bin/awg-ui"
AWGUI_LOG="/var/log/awg-ui-install.log"

AWGUI_DIR="/etc/amnezia"
AWGUI_CONFIG_DIR="/etc/amnezia/amneziawg"
AWGUI_DATA_DIR="/var/lib/awg-ui"
AWGUI_ALLOW_FILE="/etc/amnezia/allowed-ips.txt"
AWGUI_CUSTOM_CIDR="/etc/amnezia/custom-geo.cidr"
AWGUI_ENV_FILE="/etc/default/awg-ui"

AWGUI_VPN_IF="${AWGUI_VPN_IF:-awg0}"
AWGUI_LISTEN_PORT="${AWGUI_LISTEN_PORT:-51820}"
AWGUI_LAN_CIDR="${AWGUI_LAN_CIDR:-}"
AWGUI_LAN_IF="${AWGUI_LAN_IF:-}"
AWGUI_PROXY_BIND="${AWGUI_PROXY_BIND:-}"
AWGUI_HTTP_PORT="${AWGUI_HTTP_PORT:-3128}"
AWGUI_SOCKS_PORT="${AWGUI_SOCKS_PORT:-1080}"
AWGUI_DNS_1="${AWGUI_DNS_1:-1.1.1.1}"
AWGUI_DNS_2="${AWGUI_DNS_2:-8.8.8.8}"
AWGUI_ENABLE_3PROXY="${AWGUI_ENABLE_3PROXY:-}"
AWGUI_ENABLE_UFW="${AWGUI_ENABLE_UFW:-1}"
AWGUI_ENABLE_GEO="${AWGUI_ENABLE_GEO:-0}"
AWGUI_FORCE_IPV4_APT="${AWGUI_FORCE_IPV4_APT:-0}"
AWGUI_INSTALL_DEBUG_TOOLS="${AWGUI_INSTALL_DEBUG_TOOLS:-0}"
AWGUI_REPO="${AWGUI_REPO:-dmigorg/awg-ui}"
AWGUI_BRANCH="${AWGUI_BRANCH:-main}"
AWGUI_SOURCE_BASE_URL="${AWGUI_SOURCE_BASE_URL:-}"
AWGUI_3PROXY_VERSION="${AWGUI_3PROXY_VERSION:-0.9.5}"
AWGUI_KEEP_EXISTING_CONFIG=0
AWGUI_PASTE_CONFIG=0

AWGUI_INPUT_DEVICE="/dev/stdin"
if [[ -t 2 ]] && [[ -r /dev/tty ]]; then
  AWGUI_INPUT_DEVICE="/dev/tty"
fi

if [[ "${AWGUI_NONINTERACTIVE:-0}" == "1" ]] ||
   { [[ "${AWGUI_INPUT_DEVICE}" != "/dev/tty" ]] && [[ ! -t 0 ]]; }; then
  NONINTERACTIVE=1
else
  NONINTERACTIVE=0
fi

if [[ -n "${BASH_SOURCE[0]:-}" ]] &&
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; then
  :
else
  SCRIPT_DIR="$(pwd)"
fi

function info() {
  echo -e "${green}$*${plain}"
}

function warn() {
  echo -e "${yellow}$*${plain}" >&2
}

function die() {
  echo -e "${red}ERROR:${plain} $*" >&2
  exit 1
}

function require_root() {
  [[ "${EUID}" -eq 0 ]] && return 0

  die "Please run as root: sudo bash install.sh"
}

function usage() {
  cat <<EOF
Usage:
  sudo bash install.sh [--help]

Local test:
  sudo bash install.sh

GitHub install:
  curl -fsSL https://raw.githubusercontent.com/dmigorg/awg-ui/main/install.sh | sudo bash

Environment:
  AWGUI_NONINTERACTIVE=1
  AWGUI_REPO=dmigorg/awg-ui
  AWGUI_LAN_IF=eth0
  AWGUI_LAN_CIDR=192.168.1.0/24
  AWGUI_PROXY_BIND=192.168.1.10
  AWGUI_LISTEN_PORT=51820
  AWGUI_CONFIG_FILE=/root/awg0.conf
  AWGUI_CONFIG_URL=https://example.com/awg0.conf
  AWGUI_CONFIG_TEXT='[Interface]...'
  AWGUI_HTTP_PORT=3128
  AWGUI_SOCKS_PORT=1080
  AWGUI_DNS_1=1.1.1.1
  AWGUI_DNS_2=8.8.8.8
  AWGUI_ENABLE_3PROXY=1
  AWGUI_ENABLE_GEO=0
EOF
}

function command_exists() {
  command -v "$1" >/dev/null 2>&1
}

function is_3proxy_installed() {
  command_exists 3proxy &&
    command_exists systemctl &&
    systemctl cat 3proxy.service >/dev/null 2>&1
}

function read_user_input() {
  local __var="$1" __prompt="$2" __input

  IFS= read -r -p "${__prompt}" __input < "${AWGUI_INPUT_DEVICE}" ||
    die "Unable to read input from ${AWGUI_INPUT_DEVICE}"
  printf -v "${__var}" '%s' "${__input}"
}

function prompt_or_default() {
  local __var="$1" __prompt="$2" __default="$3" __env="${4:-$1}"

  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    printf -v "${__var}" '%s' "${!__env:-${__default}}"
  else
    read_user_input "${__var}" "${__prompt}"
    if [[ -z "${!__var}" ]]; then
      printf -v "${__var}" '%s' "${__default}"
    fi
  fi
}

function prompt_yes_no() {
  local __var="$1" __prompt="$2" __default="$3" __env="${4:-$1}"
  local answer

  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    answer="${!__env:-${__default}}"
  else
    read_user_input answer "${__prompt}"
    answer="${answer:-${__default}}"
  fi

  case "${answer,,}" in
    1|y|yes|true|on)
      printf -v "${__var}" '%s' "1"
      ;;
    0|n|no|false|off)
      printf -v "${__var}" '%s' "0"
      ;;
    *)
      die "Invalid yes/no value for ${__var}: ${answer}"
      ;;
  esac
}

function init_log() {
  touch "${AWGUI_LOG}" 2>/dev/null || true
  chmod 600 "${AWGUI_LOG}" 2>/dev/null || true
}

function print_source_hint() {
  if [[ -s "${SCRIPT_DIR}/awg-ui" ]]; then
    info "Source mode: local repository directory"
  elif [[ -n "${AWGUI_SOURCE_BASE_URL}" ]]; then
    info "Source base URL: ${AWGUI_SOURCE_BASE_URL}"
  elif [[ -n "${AWGUI_REPO}" ]]; then
    info "Source repo: ${AWGUI_REPO} (${AWGUI_BRANCH})"
  else
    info "Source mode: local repository directory"
  fi
}

function detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    release="${ID}"
  else
    die "Cannot detect OS. /etc/os-release is missing."
  fi

  case "${release}" in
    ubuntu|debian|armbian|linuxmint)
      ;;
    *)
      if [[ " ${ID_LIKE:-} " == *" debian "* ]] || [[ " ${ID_LIKE:-} " == *" ubuntu "* ]]; then
        warn "OS ${release} is not explicitly listed, but ID_LIKE=${ID_LIKE}. Continuing with Debian/Ubuntu install path."
      else
        die "Unsupported OS for this installer stage: ${release}. Ubuntu/Debian-compatible systems are supported now."
      fi
      ;;
  esac

  info "OS: ${PRETTY_NAME:-${release}}"
}

function is_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local a b c d octet
  IFS='.' read -r a b c d <<< "${ip}"
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

function is_cidr_or_ip() {
  local value="$1"
  [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1

  local ip="${value%%/*}"
  local prefix=""
  if [[ "${value}" == */* ]]; then
    prefix="${value##*/}"
    [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1
    (( prefix >= 0 && prefix <= 32 )) || return 1
  fi

  is_ipv4 "${ip}"
}

function cidr_network() {
  local cidr="$1" ip prefix o1 o2 o3 o4 ip_int mask network

  ip="${cidr%/*}"
  prefix="${cidr#*/}"

  is_ipv4 "${ip}" || return 1
  [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 0 && prefix <= 32 )) || return 1

  IFS='.' read -r o1 o2 o3 o4 <<< "${ip}"
  ip_int=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
  if (( prefix == 0 )); then
    mask=0
  else
    mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
  fi
  network=$(( ip_int & mask ))

  printf '%d.%d.%d.%d/%d\n' \
    $(( (network >> 24) & 255 )) \
    $(( (network >> 16) & 255 )) \
    $(( (network >> 8) & 255 )) \
    $(( network & 255 )) \
    "${prefix}"
}

function detect_default_iface() {
  ip -4 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

function first_global_ipv4_cidr() {
  local iface="$1" found
  found="$(ip -o -4 addr show dev "${iface}" scope global 2>/dev/null | awk '{print $4; exit}')"
  if [[ -n "${found}" ]]; then
    echo "${found}"
    return 0
  fi
  ip -o -4 addr show dev "${iface}" 2>/dev/null | awk '{print $4; exit}'
}

function detect_lan_defaults() {
  local iface_addr

  if [[ -z "${AWGUI_LAN_IF}" ]]; then
    AWGUI_LAN_IF="$(detect_default_iface)"
  fi

  if [[ -n "${AWGUI_LAN_IF}" ]]; then
    iface_addr="$(first_global_ipv4_cidr "${AWGUI_LAN_IF}")"

    if [[ -z "${AWGUI_PROXY_BIND}" && -n "${iface_addr}" ]]; then
      AWGUI_PROXY_BIND="${iface_addr%/*}"
    fi

    if [[ -z "${AWGUI_LAN_CIDR}" && -n "${iface_addr}" ]]; then
      AWGUI_LAN_CIDR="$(cidr_network "${iface_addr}")"
    fi
  fi
}

function backup_file() {
  local file="$1"
  local backup_dir
  backup_dir="/var/backups/awg-ui/$(date +%Y%m%d-%H%M%S)"

  [[ -e "${file}" ]] || return 0
  install -d -m 700 "${backup_dir}"
  cp -a "${file}" "${backup_dir}/"
  info "Backup: ${file} -> ${backup_dir}/"
}

function install_base_packages() {
  local packages
  packages=(
    curl
    ca-certificates
    gnupg2
    software-properties-common
    python3-launchpadlib
    dkms
    build-essential
    iproute2
    nftables
    ufw
    dnsutils
    tar
  )

  if [[ "${AWGUI_INSTALL_DEBUG_TOOLS}" == "1" ]]; then
    packages+=(traceroute tcpdump)
  fi

  if [[ "${AWGUI_FORCE_IPV4_APT}" == "1" ]]; then
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
  fi

  info "Installing base packages..."
  apt-get update
  apt-get install -y -q "${packages[@]}"

  if ! dpkg -l | grep -q "linux-headers-$(uname -r)"; then
    apt-get install -y -q "linux-headers-$(uname -r)" || apt-get install -y -q linux-headers-generic || true
  fi
}

function install_amneziawg() {
  if command_exists awg && command_exists awg-quick; then
    info "AmneziaWG is already installed."
    return 0
  fi

  info "Installing AmneziaWG..."
  add-apt-repository -y ppa:amnezia/ppa
  apt-get update
  apt-get install -y -q amneziawg
  modprobe amneziawg 2>/dev/null || true

  command_exists awg || die "awg command not found after install"
  command_exists awg-quick || die "awg-quick command not found after install"
}

function install_3proxy() {
  if command_exists 3proxy; then
    info "3proxy is already installed: $(command -v 3proxy)"
    return 0
  fi

  if apt-cache show 3proxy >/dev/null 2>&1; then
    info "Installing 3proxy from apt..."
    apt-get install -y -q 3proxy
  else
    info "3proxy package is not available in apt. Building 3proxy ${AWGUI_3PROXY_VERSION} from source..."

    local build_dir
    build_dir="$(mktemp -d)"

    curl -fL --retry 5 \
      -o "${build_dir}/3proxy.tar.gz" \
      "https://github.com/3proxy/3proxy/archive/refs/tags/${AWGUI_3PROXY_VERSION}.tar.gz"

    mkdir -p "${build_dir}/src"
    tar -xzf "${build_dir}/3proxy.tar.gz" -C "${build_dir}/src" --strip-components=1

    make -C "${build_dir}/src" -f Makefile.Linux
    install -m 755 -o root -g root "${build_dir}/src/bin/3proxy" /usr/local/bin/3proxy

    rm -rf "${build_dir}"
  fi

  command_exists 3proxy || die "3proxy command not found after install"
}

function prepare_dirs() {
  install -d -m 700 "${AWGUI_DIR}"
  install -d -m 700 "${AWGUI_CONFIG_DIR}"
  install -d -m 700 "${AWGUI_DATA_DIR}"
  install -d -m 755 "${AWGUI_APP_DIR}"
  install -d -m 755 /usr/bin

  touch "${AWGUI_ALLOW_FILE}" "${AWGUI_CUSTOM_CIDR}"
  chmod 600 "${AWGUI_ALLOW_FILE}" "${AWGUI_CUSTOM_CIDR}"
}

function fetch_source_file() {
  local name="$1"
  local dest="$2"
  local local_file="${SCRIPT_DIR}/${name}"
  local source_base_url="${AWGUI_SOURCE_BASE_URL}"

  if [[ -s "${local_file}" ]]; then
    cp "${local_file}" "${dest}"
    return 0
  fi

  if [[ -z "${source_base_url}" && -n "${AWGUI_REPO}" ]]; then
    source_base_url="https://raw.githubusercontent.com/${AWGUI_REPO}/${AWGUI_BRANCH}"
  fi

  if [[ -n "${source_base_url}" ]]; then
    curl -fL --retry 5 -o "${dest}" "${source_base_url%/}/${name}"
    return 0
  fi

  die "Cannot find ${name}. Run from repo root, or set AWGUI_REPO=owner/repo, or set AWGUI_SOURCE_BASE_URL."
}

function write_awg_common_file() {
  info "Writing ${AWGUI_COMMON}..."

  backup_file "${AWGUI_COMMON}"
  cat > "${AWGUI_COMMON}" <<'AWG_COMMON_EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2034

if [[ "${AWG_COMMON_LOADED:-0}" == "1" ]]; then
  return 0
fi

readonly AWG_COMMON_LOADED="1"

readonly AWG_RED='\033[0;31m'
readonly AWG_GREEN='\033[0;32m'
readonly AWG_ORANGE='\033[0;33m'
readonly AWG_NC='\033[0m'

readonly AWG_DIR="/etc/amnezia"
readonly AWG_CONFIG_DIR="/etc/amnezia/amneziawg"
readonly AWG_ALLOW_FILE="/etc/amnezia/allowed-ips.txt"
readonly AWG_CUSTOM_CIDR="/etc/amnezia/custom-geo.cidr"
readonly AWG_ENV_FILE="/etc/default/awg-ui"
readonly AWG_INSTALLER="/usr/local/awg-ui/install.sh"

if [[ -f "${AWG_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${AWG_ENV_FILE}"
fi

readonly AWG_DATA_DIR="/var/lib/awg-ui"
readonly AWG_GEOIP_RU_DAT="${AWG_DATA_DIR}/geoip_RU.dat"
readonly AWG_GEOSITE_RU_DAT="${AWG_DATA_DIR}/geosite_RU.dat"
readonly AWG_RU_WHITELIST_CIDR="${AWG_DATA_DIR}/ru-whitelist.cidr"
readonly AWG_NFT_FILE="${AWG_DATA_DIR}/awg-geo.nft"
readonly AWG_NFT_HASH_FILE="${AWG_DATA_DIR}/awg-geo.hash"

readonly AWG_NFT_TABLE="awg_geo"
readonly AWG_NFT_SET_RU="ru_whitelist4"
readonly AWG_NFT_SET_CUSTOM="custom_bypass4"

readonly AWG_FWMARK="0x66"
readonly AWG_ROUTE_TABLE_ID="166"
readonly AWG_ROUTE_TABLE_NAME="awg_ru_bypass"
readonly AWG_ROUTE_RULE_PREF="10"

readonly AWG_UFW_TAG="AMNEZIAWG"
readonly AWG_LAN_CIDR="${AWG_LAN_CIDR:-}"

readonly AWG_GEOIP_RU_URL="https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat"
readonly AWG_GEOSITE_RU_URL="https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat"
readonly AWG_RU_WHITELIST_URL="https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main/cidrwhitelist.txt"

function awg_die() {
  echo -e "${AWG_RED}ERROR:${AWG_NC} $*" >&2
  exit 1
}

function awg_info() {
  echo -e "${AWG_GREEN}$*${AWG_NC}"
}

function awg_warn() {
  echo -e "${AWG_ORANGE}$*${AWG_NC}"
}

function awg_require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    awg_die "Run as root: sudo $0 $*"
  fi
}

function awg_require_command() {
  local command="$1"

  command -v "${command}" >/dev/null 2>&1 || awg_die "${command} not found"
}

function awg_check_base_commands() {
  awg_require_command ip
  awg_require_command awk
  awg_require_command grep
  awg_require_command sed
  awg_require_command sort
}

function awg_check_ufw_commands() {
  awg_check_base_commands
  awg_require_command ufw
}

function awg_check_firewall_commands() {
  awg_check_base_commands
  awg_require_command iptables
}

function awg_check_geo_commands() {
  awg_check_base_commands
  awg_require_command nft
  awg_require_command sha256sum
}

function awg_check_update_commands() {
  awg_check_geo_commands
  awg_require_command curl
}

function awg_check_system_commands() {
  awg_check_base_commands
  awg_require_command systemctl
}

function awg_prepare_dirs() {
  mkdir -p "${AWG_DIR}"
  chmod 700 "${AWG_DIR}"

  mkdir -p "${AWG_CONFIG_DIR}"
  chmod 700 "${AWG_CONFIG_DIR}"

  mkdir -p "${AWG_DATA_DIR}"
  chmod 700 "${AWG_DATA_DIR}"

  touch "${AWG_ALLOW_FILE}"
  chmod 600 "${AWG_ALLOW_FILE}"

  touch "${AWG_CUSTOM_CIDR}"
  chmod 600 "${AWG_CUSTOM_CIDR}"
}

function awg_is_valid_ipv4() {
  local ip="$1"

  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local a b c d
  IFS='.' read -r a b c d <<< "${ip}"

  for octet in "$a" "$b" "$c" "$d"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done

  return 0
}

function awg_is_valid_cidr_or_ip() {
  local value="$1"

  [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1

  local ip="${value%%/*}"
  local prefix=""

  if [[ "${value}" == */* ]]; then
    prefix="${value##*/}"
    [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1
    (( prefix >= 0 && prefix <= 32 )) || return 1
  fi

  awg_is_valid_ipv4 "${ip}"
}

function awg_require_ip_arg() {
  local ip="${1:-}"

  [[ -n "${ip}" ]] || awg_die "IP address is required"

  if ! awg_is_valid_ipv4 "${ip}"; then
    awg_die "Invalid IPv4 address: ${ip}"
  fi

  echo "${ip}"
}

function awg_detect_vpn_if() {
  local vpn_if=""

  if command -v awg >/dev/null 2>&1; then
    vpn_if="$(awg show interfaces 2>/dev/null | awk '{print $1; exit}')"
  fi

  if [[ -n "${vpn_if}" ]]; then
    echo "${vpn_if}"
    return 0
  fi

  local configs=()

  if compgen -G "${AWG_CONFIG_DIR}/*.conf" >/dev/null; then
    while IFS= read -r config; do
      configs+=("$(basename "${config}" .conf)")
    done < <(find "${AWG_CONFIG_DIR}" -maxdepth 1 -type f -name '*.conf' | sort)
  fi

  if [[ "${#configs[@]}" -eq 1 ]]; then
    echo "${configs[0]}"
    return 0
  fi

  if [[ "${#configs[@]}" -gt 1 ]]; then
    for candidate in awg0 amn0 wg0; do
      for config_if in "${configs[@]}"; do
        if [[ "${config_if}" == "${candidate}" ]]; then
          echo "${config_if}"
          return 0
        fi
      done
    done

    echo "Found multiple AmneziaWG configs:" >&2
    printf '  %s\n' "${configs[@]}" >&2
    awg_die "Cannot choose VPN interface automatically"
  fi

  if ip link show awg0 >/dev/null 2>&1; then
    echo "awg0"
    return 0
  fi

  awg_die "Cannot detect AmneziaWG interface. Expected config: ${AWG_CONFIG_DIR}/<interface>.conf"
}

function awg_detect_vpn_service() {
  local vpn_if
  vpn_if="$(awg_detect_vpn_if)"

  echo "awg-quick@${vpn_if}.service"
}

function awg_route_line_to_dev() {
  local route_line="$1"

  echo "${route_line}" \
    | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

function awg_route_line_to_gw() {
  local route_line="$1"

  echo "${route_line}" \
    | awk '{for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}'
}

function awg_get_endpoint_ip() {
  local vpn_if="$1"
  local endpoint=""

  if ! command -v awg >/dev/null 2>&1; then
    return 0
  fi

  endpoint="$(awg show "${vpn_if}" endpoints 2>/dev/null | awk '{print $2; exit}')"

  [[ -n "${endpoint}" ]] || return 0
  [[ "${endpoint}" == "(none)" ]] && return 0

  endpoint="${endpoint%:*}"

  if awg_is_valid_ipv4 "${endpoint}"; then
    echo "${endpoint}"
  fi
}

function awg_detect_bypass_route() {
  local vpn_if="$1"
  local route_line=""
  local endpoint_ip=""

  route_line="$(
    ip -4 route show default \
      | awk -v vpn="${vpn_if}" '$0 !~ ("dev " vpn) {print; exit}'
  )"

  if [[ -n "${route_line}" ]]; then
    echo "${route_line}"
    return 0
  fi

  endpoint_ip="$(awg_get_endpoint_ip "${vpn_if}")"

  if [[ -n "${endpoint_ip}" ]]; then
    route_line="$(
      ip -4 route get "${endpoint_ip}" 2>/dev/null \
        | awk -v vpn="${vpn_if}" '$0 !~ ("dev " vpn) {print; exit}'
    )"

    if [[ -n "${route_line}" ]]; then
      echo "${route_line}"
      return 0
    fi
  fi

  awg_die "Cannot detect non-VPN bypass route"
}

function awg_detect_lan_if_for_ip() {
  local ip="$1"
  local lan_if=""

  lan_if="$(
    ip -4 route get "${ip}" 2>/dev/null \
      | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
  )"

  [[ -n "${lan_if}" ]] || awg_die "Cannot detect LAN interface for IP: ${ip}"

  echo "${lan_if}"
}

function awg_prepare_route_table_name() {
  touch /etc/iproute2/rt_tables

  if ! grep -qE "^[[:space:]]*${AWG_ROUTE_TABLE_ID}[[:space:]]+${AWG_ROUTE_TABLE_NAME}$" /etc/iproute2/rt_tables; then
    echo "${AWG_ROUTE_TABLE_ID} ${AWG_ROUTE_TABLE_NAME}" >> /etc/iproute2/rt_tables
  fi
}

function awg_prepare_forwarding() {
  local vpn_if
  local route_line
  local bypass_if

  vpn_if="$(awg_detect_vpn_if)"
  route_line="$(awg_detect_bypass_route "${vpn_if}")"
  bypass_if="$(awg_route_line_to_dev "${route_line}")"

  [[ -n "${vpn_if}" ]] || awg_die "Cannot detect VPN interface"
  [[ -n "${bypass_if}" ]] || awg_die "Cannot detect bypass interface"

  cat > /etc/sysctl.d/99-amneziawg-forward.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
EOF

  {
    echo "net.ipv4.conf.all.rp_filter=0"
    echo "net.ipv4.conf.default.rp_filter=0"
  } > /etc/sysctl.d/98-amneziawg-rpfilter.conf

  sysctl --system >/dev/null

  if [[ -d "/proc/sys/net/ipv4/conf/${vpn_if}" ]]; then
    sysctl -w "net.ipv4.conf.${vpn_if}.forwarding=1" >/dev/null
    sysctl -w "net.ipv4.conf.${vpn_if}.rp_filter=0" >/dev/null
  fi

  if [[ -d "/proc/sys/net/ipv4/conf/${bypass_if}" ]]; then
    sysctl -w "net.ipv4.conf.${bypass_if}.forwarding=1" >/dev/null
    sysctl -w "net.ipv4.conf.${bypass_if}.rp_filter=0" >/dev/null
  fi
}
AWG_COMMON_EOF
  chmod 644 "${AWGUI_COMMON}"
  bash -n "${AWGUI_COMMON}"
}

function install_awg_ui_files() {
  local cli_temp="/usr/bin/awg-ui-temp.$$"
  local installer_temp="${AWGUI_APP_DIR}/install.sh.tmp.$$"
  rm -f "${cli_temp}"
  rm -f "${installer_temp}"

  fetch_source_file "awg-ui" "${cli_temp}"
  fetch_source_file "install.sh" "${installer_temp}"

  if [[ ! -s "${cli_temp}" ]]; then
    rm -f "${cli_temp}"
    die "Downloaded awg-ui is empty"
  fi

  if [[ ! -s "${installer_temp}" ]]; then
    rm -f "${cli_temp}" "${installer_temp}"
    die "Downloaded install.sh is empty"
  fi

  bash -n "${cli_temp}"
  bash -n "${installer_temp}"

  backup_file "${AWGUI_CLI}"
  backup_file "${AWGUI_CLI_SOURCE}"
  backup_file "${AWGUI_INSTALLER}"

  mv -f "${cli_temp}" "${AWGUI_CLI}"
  install -m 700 -o root -g root "${AWGUI_CLI}" "${AWGUI_CLI_SOURCE}"
  mv -f "${installer_temp}" "${AWGUI_INSTALLER}"
  chmod 700 "${AWGUI_CLI}"
  chmod 700 "${AWGUI_INSTALLER}"
  write_awg_common_file

  info "Installed ${AWGUI_CLI}, ${AWGUI_INSTALLER}, and ${AWGUI_COMMON}."
}

function import_existing_config_dir() {
  if [[ -d /etc/amneziawg ]] && ! compgen -G "${AWGUI_CONFIG_DIR}/*.conf" >/dev/null; then
    warn "Found legacy /etc/amneziawg. Copying configs to ${AWGUI_CONFIG_DIR}."
    cp -a /etc/amneziawg/*.conf "${AWGUI_CONFIG_DIR}/" 2>/dev/null || true
    chmod 600 "${AWGUI_CONFIG_DIR}"/*.conf 2>/dev/null || true
  fi
}

function validate_awg_config_file() {
  local config="$1"

  [[ -s "${config}" ]] || die "AWG config is empty: ${config}"
  grep -Eq '^[[:space:]]*\[Interface\][[:space:]]*$' "${config}" || die "AWG config must contain [Interface]: ${config}"
  grep -Eq '^[[:space:]]*PrivateKey[[:space:]]*=' "${config}" || die "AWG config must contain Interface PrivateKey: ${config}"
}

function choose_awg_config_source() {
  local choice=""
  local has_existing=0

  if compgen -G "${AWGUI_CONFIG_DIR}/*.conf" >/dev/null; then
    has_existing=1
  fi

  if [[ -n "${AWGUI_CONFIG_FILE:-}" ]] ||
     [[ -n "${AWGUI_CONFIG_URL:-}" ]] ||
     [[ -n "${AWGUI_CONFIG_TEXT:-}" ]]; then
    return 0
  fi

  if [[ "${has_existing}" == "1" ]] && [[ "${NONINTERACTIVE}" == "1" ]]; then
    AWGUI_KEEP_EXISTING_CONFIG=1
    return 0
  fi

  [[ "${NONINTERACTIVE}" != "1" ]] ||
    die "No AWG config found. Set AWGUI_CONFIG_FILE, AWGUI_CONFIG_URL, or AWGUI_CONFIG_TEXT."

  while true; do
    echo
    if [[ "${has_existing}" == "1" ]]; then
      echo "An existing AmneziaWG configuration was found:"
      find "${AWGUI_CONFIG_DIR}" -maxdepth 1 -type f -name '*.conf' -print | sort | sed 's/^/  /'
      echo
      echo "Choose what to do with the configuration:"
      echo "  1. Keep the existing configuration"
      echo "  2. Replace it with a local configuration file"
      echo "  3. Replace it with a configuration downloaded from URL"
      echo "  4. Replace it by pasting a configuration manually"
      echo "  0. Cancel installation"
      read_user_input choice "Choose an option [1-4, 0]: "
    else
      echo "No AmneziaWG configuration was found. Choose its source:"
      echo "  1. Local configuration file"
      echo "  2. Download from URL"
      echo "  3. Paste configuration manually"
      echo "  0. Cancel installation"
      read_user_input choice "Choose an option [1-3, 0]: "
    fi

    if [[ "${has_existing}" == "1" ]]; then
      case "${choice}" in
        1)
          AWGUI_KEEP_EXISTING_CONFIG=1
          return 0
          ;;
        2) choice=1 ;;
        3) choice=2 ;;
        4) choice=3 ;;
      esac
    fi

    case "${choice}" in
      1)
        read_user_input AWGUI_CONFIG_FILE "Enter the full path to the config file: "
        if [[ ! -s "${AWGUI_CONFIG_FILE}" ]]; then
          warn "Config file does not exist or is empty: ${AWGUI_CONFIG_FILE:-<empty>}"
          AWGUI_CONFIG_FILE=""
          continue
        fi
        return 0
        ;;
      2)
        read_user_input AWGUI_CONFIG_URL "Enter the config URL: "
        if [[ -z "${AWGUI_CONFIG_URL}" ]]; then
          warn "Config URL cannot be empty."
          continue
        fi
        return 0
        ;;
      3)
        AWGUI_PASTE_CONFIG=1
        return 0
        ;;
      0)
        die "Installation cancelled."
        ;;
      *)
        warn "Invalid option: ${choice:-<empty>}"
        ;;
    esac
  done
}

function install_validated_config() {
  local source_config="$1"
  local server_config="${AWGUI_CONFIG_DIR}/${AWGUI_VPN_IF}.conf"

  validate_awg_config_file "${source_config}"

  if [[ "$(readlink -f "${source_config}")" == "$(readlink -f "${server_config}")" ]]; then
    chmod 600 "${server_config}"
    info "Using AWG config: ${server_config}"
    return 0
  fi

  backup_file "${server_config}"
  install -m 600 -o root -g root "${source_config}" "${server_config}"
  info "Installed AWG config: ${server_config}"
}

function install_config_from_env() {
  local tmp

  if [[ "${AWGUI_KEEP_EXISTING_CONFIG}" == "1" ]]; then
    info "Keeping the existing AmneziaWG configuration."
    return 0
  fi

  if [[ -n "${AWGUI_CONFIG_FILE:-}" ]]; then
    [[ -s "${AWGUI_CONFIG_FILE}" ]] || die "AWGUI_CONFIG_FILE does not exist: ${AWGUI_CONFIG_FILE}"
    install_validated_config "${AWGUI_CONFIG_FILE}"
    return 0
  fi

  if [[ -n "${AWGUI_CONFIG_URL:-}" ]]; then
    command_exists curl || die "curl is required to download AWGUI_CONFIG_URL: ${AWGUI_CONFIG_URL}"
    tmp="$(mktemp)"
    if ! curl -fL --retry 5 -o "${tmp}" "${AWGUI_CONFIG_URL}"; then
      rm -f "${tmp}"
      die "Cannot download AWG config from URL: ${AWGUI_CONFIG_URL}"
    fi
    install_validated_config "${tmp}"
    rm -f "${tmp}"
    return 0
  fi

  if [[ -n "${AWGUI_CONFIG_TEXT:-}" ]]; then
    tmp="$(mktemp)"
    printf '%s\n' "${AWGUI_CONFIG_TEXT}" > "${tmp}"
    install_validated_config "${tmp}"
    rm -f "${tmp}"
    return 0
  fi
}

function paste_awg_config_if_missing() {
  local server_config="${AWGUI_CONFIG_DIR}/${AWGUI_VPN_IF}.conf"
  local tmp line

  if [[ "${AWGUI_KEEP_EXISTING_CONFIG}" == "1" ]]; then
    return 0
  fi

  if [[ "${AWGUI_PASTE_CONFIG}" != "1" ]] &&
     compgen -G "${AWGUI_CONFIG_DIR}/*.conf" >/dev/null; then
    return 0
  fi

  [[ "${NONINTERACTIVE}" != "1" ]] || die "No AWG config found. Set AWGUI_CONFIG_FILE, AWGUI_CONFIG_URL, or AWGUI_CONFIG_TEXT."

  info "Paste AmneziaWG config for ${AWGUI_VPN_IF}. Finish with a line containing only EOF."
  tmp="$(mktemp)"

  while IFS= read -r line; do
    [[ "${line}" == "EOF" ]] && break
    printf '%s\n' "${line}" >> "${tmp}"
  done < "${AWGUI_INPUT_DEVICE}"

  [[ -s "${tmp}" ]] || {
    rm -f "${tmp}"
    die "Pasted AWG config is empty"
  }

  grep -Eq '^[[:space:]]*\[Interface\][[:space:]]*$' "${tmp}" || {
    rm -f "${tmp}"
    die "Pasted AWG config must contain [Interface]"
  }

  grep -Eq '^[[:space:]]*PrivateKey[[:space:]]*=' "${tmp}" || {
    rm -f "${tmp}"
    die "Pasted AWG config must contain Interface PrivateKey"
  }

  backup_file "${server_config}"
  install -m 600 -o root -g root "${tmp}" "${server_config}"
  rm -f "${tmp}"

  info "Saved AWG config: ${server_config}"
}

function detect_listen_port_from_config() {
  local config="${AWGUI_CONFIG_DIR}/${AWGUI_VPN_IF}.conf"
  local detected=""

  [[ -f "${config}" ]] || return 0

  detected="$(awk -F= '
    $1 ~ /^[[:space:]]*ListenPort[[:space:]]*$/ {
      gsub(/[[:space:]]/, "", $2)
      print $2
      exit
    }
  ' "${config}")"

  if [[ -n "${detected}" ]]; then
    [[ "${detected}" =~ ^[0-9]+$ ]] || die "Invalid ListenPort in ${config}: ${detected}"
    (( detected >= 1 && detected <= 65535 )) || die "Invalid ListenPort in ${config}: ${detected}"
    AWGUI_LISTEN_PORT="${detected}"
  fi
}

function detect_vpn_if() {
  local configs=()
  local config

  if compgen -G "${AWGUI_CONFIG_DIR}/*.conf" >/dev/null; then
    while IFS= read -r config; do
      configs+=("$(basename "${config}" .conf)")
    done < <(find "${AWGUI_CONFIG_DIR}" -maxdepth 1 -type f -name '*.conf' | sort)
  fi

  if [[ "${#configs[@]}" -eq 1 ]]; then
    AWGUI_VPN_IF="${configs[0]}"
  elif [[ "${#configs[@]}" -gt 1 ]]; then
    if [[ -f "${AWGUI_CONFIG_DIR}/${AWGUI_VPN_IF}.conf" ]]; then
      :
    else
      die "Multiple configs found in ${AWGUI_CONFIG_DIR}. Set AWGUI_VPN_IF."
    fi
  fi

  info "VPN interface: ${AWGUI_VPN_IF}"
}

function prepare_config_hooks() {
  local config="${AWGUI_CONFIG_DIR}/${AWGUI_VPN_IF}.conf"
  local tmp

  [[ -f "${config}" ]] || return 0

  backup_file "${config}"

  if ! grep -Fxq "PostUp = ${AWGUI_CLI} apply" "${config}"; then
    tmp="$(mktemp)"
    awk -v hook="PostUp = /usr/bin/awg-ui apply" '
      /^[[:space:]]*\[Interface\][[:space:]]*$/ && !done { print; print hook; done=1; next }
      { print }
    ' "${config}" > "${tmp}"
    install -m 600 -o root -g root "${tmp}" "${config}"
    rm -f "${tmp}"
  fi

  if ! grep -Fxq "PreDown = ${AWGUI_CLI} geo-flush" "${config}"; then
    tmp="$(mktemp)"
    awk -v hook="PreDown = /usr/bin/awg-ui geo-flush" '
      /^[[:space:]]*\[Interface\][[:space:]]*$/ && !done { print; print hook; done=1; next }
      { print }
    ' "${config}" > "${tmp}"
    install -m 600 -o root -g root "${tmp}" "${config}"
    rm -f "${tmp}"
  fi
}

function write_env_file() {
  info "Writing ${AWGUI_ENV_FILE}..."

  backup_file "${AWGUI_ENV_FILE}"
  cat > "${AWGUI_ENV_FILE}" <<EOF
AWG_LAN_CIDR="${AWGUI_LAN_CIDR}"
AWG_LAN_IF="${AWGUI_LAN_IF}"
EOF
  chmod 600 "${AWGUI_ENV_FILE}"
}

function detect_lan_values() {
  detect_lan_defaults

  [[ -n "${AWGUI_LAN_IF}" ]] || die "Cannot detect AWGUI_LAN_IF. Set it explicitly."
  [[ -n "${AWGUI_LAN_CIDR}" ]] || die "Cannot detect AWGUI_LAN_CIDR from ${AWGUI_LAN_IF}. Set it explicitly."
  if [[ "${AWGUI_ENABLE_3PROXY}" == "1" ]]; then
    [[ -n "${AWGUI_PROXY_BIND}" ]] || die "Cannot detect AWGUI_PROXY_BIND from ${AWGUI_LAN_IF}. Set it explicitly."
  fi
  is_cidr_or_ip "${AWGUI_LAN_CIDR}" || die "Invalid AWGUI_LAN_CIDR: ${AWGUI_LAN_CIDR}"
  if [[ -n "${AWGUI_PROXY_BIND}" ]]; then
    is_ipv4 "${AWGUI_PROXY_BIND}" || die "Invalid AWGUI_PROXY_BIND: ${AWGUI_PROXY_BIND}"
  fi

  info "LAN interface: ${AWGUI_LAN_IF}"
  info "LAN CIDR: ${AWGUI_LAN_CIDR}"
  if [[ "${AWGUI_ENABLE_3PROXY}" == "1" ]]; then
    info "Proxy bind: ${AWGUI_PROXY_BIND}"
  fi
}

function configure_sysctl() {
  info "Configuring sysctl..."

  backup_file /etc/sysctl.d/99-amneziawg-forward.conf
  backup_file /etc/sysctl.d/98-amneziawg-rpfilter.conf

  cat > /etc/sysctl.d/99-amneziawg-forward.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
EOF

  {
    echo "net.ipv4.conf.all.rp_filter=0"
    echo "net.ipv4.conf.default.rp_filter=0"
  } > /etc/sysctl.d/98-amneziawg-rpfilter.conf

  sysctl --system >/dev/null

  if [[ -d "/proc/sys/net/ipv4/conf/${AWGUI_LAN_IF}" ]]; then
    sysctl -w "net.ipv4.conf.${AWGUI_LAN_IF}.forwarding=1" >/dev/null
    sysctl -w "net.ipv4.conf.${AWGUI_LAN_IF}.rp_filter=0" >/dev/null
  fi

  if [[ -d "/proc/sys/net/ipv4/conf/${AWGUI_VPN_IF}" ]]; then
    sysctl -w "net.ipv4.conf.${AWGUI_VPN_IF}.forwarding=1" >/dev/null
    sysctl -w "net.ipv4.conf.${AWGUI_VPN_IF}.rp_filter=0" >/dev/null
  fi
}

function configure_3proxy() {
  [[ "${AWGUI_ENABLE_3PROXY}" == "1" ]] || {
    warn "3proxy disabled. Skipping proxy configuration."
    return 0
  }

  info "Configuring 3proxy..."

  local proxy_bin
  proxy_bin="$(command -v 3proxy || true)"
  [[ -n "${proxy_bin}" ]] || die "3proxy binary not found"

  install -d -m 755 /etc/3proxy
  install -d -m 755 /var/log/3proxy

  backup_file /etc/3proxy/3proxy.cfg
  cat > /etc/3proxy/3proxy.cfg <<EOF
nserver ${AWGUI_DNS_1}
nserver ${AWGUI_DNS_2}
nscache 65536

daemon
pidfile /run/3proxy/3proxy.pid

log /var/log/3proxy/3proxy.log D
rotate 30

internal ${AWGUI_PROXY_BIND}

auth iponly
allow * ${AWGUI_LAN_CIDR}

proxy -p${AWGUI_HTTP_PORT}
socks -p${AWGUI_SOCKS_PORT}
EOF

  backup_file /etc/systemd/system/3proxy.service
  cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy proxy server
After=network-online.target awg-quick@${AWGUI_VPN_IF}.service
Wants=network-online.target
Requires=awg-quick@${AWGUI_VPN_IF}.service

[Service]
Type=forking
PIDFile=/run/3proxy/3proxy.pid
RuntimeDirectory=3proxy
ExecStart=${proxy_bin} /etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

function configure_ufw() {
  [[ "${AWGUI_ENABLE_UFW}" == "1" ]] || return 0

  info "Configuring UFW..."

  ufw allow ssh >/dev/null || true
  ufw allow "${AWGUI_LISTEN_PORT}/udp" comment "AmneziaWG" >/dev/null || true
  if [[ "${AWGUI_ENABLE_3PROXY}" == "1" ]]; then
    ufw allow in on "${AWGUI_LAN_IF}" to any port "${AWGUI_HTTP_PORT}" proto tcp comment "3proxy HTTP" >/dev/null || true
    ufw allow in on "${AWGUI_LAN_IF}" to any port "${AWGUI_SOCKS_PORT}" proto tcp comment "3proxy SOCKS5" >/dev/null || true
  fi

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw default deny routed >/dev/null

  if grep -q '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw; then
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw
  else
    echo 'DEFAULT_FORWARD_POLICY="DROP"' >> /etc/default/ufw
  fi

  ufw --force enable >/dev/null
}

function enable_services() {
  info "Enabling services..."

  systemctl daemon-reload
  systemctl enable --now nftables
  systemctl is-active --quiet nftables || die "nftables service is not active"

  if [[ -f "${AWGUI_CONFIG_DIR}/${AWGUI_VPN_IF}.conf" ]]; then
    systemctl enable "awg-quick@${AWGUI_VPN_IF}.service"
    if ! systemctl restart "awg-quick@${AWGUI_VPN_IF}.service"; then
      systemctl status "awg-quick@${AWGUI_VPN_IF}.service" --no-pager || true
      die "Failed to start awg-quick@${AWGUI_VPN_IF}.service"
    fi
    systemctl is-active --quiet "awg-quick@${AWGUI_VPN_IF}.service" || die "awg-quick@${AWGUI_VPN_IF}.service is not active"
    if [[ "${AWGUI_ENABLE_3PROXY}" == "1" ]]; then
      systemctl enable 3proxy.service
      if ! systemctl restart 3proxy.service; then
        systemctl status 3proxy.service --no-pager || true
        die "Failed to start 3proxy.service"
      fi
      systemctl is-active --quiet 3proxy.service || die "3proxy.service is not active"
    fi
  else
    warn "Skipping awg-quick start because ${AWGUI_CONFIG_DIR}/${AWGUI_VPN_IF}.conf is missing."
    if [[ "${AWGUI_ENABLE_3PROXY}" == "1" ]]; then
      warn "Skipping 3proxy start because it requires awg-quick@${AWGUI_VPN_IF}.service."
    fi
  fi
}

function apply_runtime_rules() {
  info "Applying awg-ui runtime rules..."

  if [[ -f "${AWGUI_CONFIG_DIR}/${AWGUI_VPN_IF}.conf" ]]; then
    AWG_LAN_CIDR="${AWGUI_LAN_CIDR}" "${AWGUI_CLI}" apply || warn "awg-ui apply failed. Check ${AWGUI_LOG} and awg-ui status."
  fi

  if [[ "${AWGUI_ENABLE_GEO}" == "1" ]]; then
    AWG_LAN_CIDR="${AWGUI_LAN_CIDR}" "${AWGUI_CLI}" geo-sync || warn "geo-sync failed."
  fi
}

function print_summary() {
  echo
  echo "======================================================="
  echo -e "  ${blue}awg-ui installed${plain}"
  echo
  echo -e "  ${blue}awg-ui status${plain}       Show full status"
  echo -e "  ${blue}awg-ui add <ip>${plain}     Add LAN client"
  echo -e "  ${blue}awg-ui del <ip>${plain}     Remove LAN client"
  echo -e "  ${blue}awg-ui restart${plain}      Restart AmneziaWG and rules"
  if is_3proxy_installed; then
    echo -e "  ${blue}awg-ui stop${plain}         Stop AmneziaWG and 3proxy"
    echo -e "  ${blue}awg-ui restart-3proxy${plain} Restart 3proxy"
  else
    echo -e "  ${blue}awg-ui stop${plain}         Stop AmneziaWG"
    echo -e "  ${blue}awg-ui install-3proxy${plain} Install and configure 3proxy"
  fi
  echo -e "  ${blue}awg-ui geo-sync${plain}     Update and apply geo bypass"
  echo -e "  ${blue}awg-ui geo-flush${plain}    Remove geo bypass rules"
  echo
  if [[ "${AWGUI_ENABLE_3PROXY}" == "1" ]]; then
    echo "  HTTP proxy:  ${AWGUI_PROXY_BIND}:${AWGUI_HTTP_PORT}"
    echo "  SOCKS proxy: ${AWGUI_PROXY_BIND}:${AWGUI_SOCKS_PORT}"
  else
    echo "  3proxy:      disabled"
  fi
  echo "  Log file:    ${AWGUI_LOG}"
  echo "======================================================="
}

function main() {
  case "${1:-}" in
    --help|-h|help)
      usage
      return 0
      ;;
  esac

  echo "Starting awg-ui installer..."
  require_root
  init_log
  info "Log file: ${AWGUI_LOG}"
  print_source_hint
  detect_os

  info "Checking AmneziaWG configuration..."
  prepare_dirs
  import_existing_config_dir
  detect_vpn_if
  choose_awg_config_source
  install_config_from_env
  paste_awg_config_if_missing
  validate_awg_config_file "${AWGUI_CONFIG_DIR}/${AWGUI_VPN_IF}.conf"
  detect_listen_port_from_config

  detect_lan_defaults

  prompt_or_default AWGUI_LAN_CIDR "LAN CIDR allowed to use proxy/VPN [${AWGUI_LAN_CIDR:-auto-detect}]: " "${AWGUI_LAN_CIDR}" AWGUI_LAN_CIDR
  prompt_yes_no AWGUI_ENABLE_3PROXY "Install and configure 3proxy HTTP/SOCKS proxy? [y/N]: " "n" AWGUI_ENABLE_3PROXY

  if [[ "${AWGUI_ENABLE_3PROXY}" == "1" ]]; then
    prompt_or_default AWGUI_HTTP_PORT "HTTP proxy port [${AWGUI_HTTP_PORT}]: " "${AWGUI_HTTP_PORT}" AWGUI_HTTP_PORT
    prompt_or_default AWGUI_SOCKS_PORT "SOCKS5 proxy port [${AWGUI_SOCKS_PORT}]: " "${AWGUI_SOCKS_PORT}" AWGUI_SOCKS_PORT
  fi

  install_base_packages
  install_amneziawg
  if [[ "${AWGUI_ENABLE_3PROXY}" == "1" ]]; then
    install_3proxy
  fi
  install_awg_ui_files
  detect_lan_values
  write_env_file
  prepare_config_hooks
  configure_sysctl
  configure_3proxy
  configure_ufw
  enable_services
  apply_runtime_rules
  print_summary
}

main "$@"
