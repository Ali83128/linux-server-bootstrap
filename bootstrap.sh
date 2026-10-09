#!/usr/bin/env bash
#
# linux-server-bootstrap
# Turns a fresh Ubuntu 22.04 / 24.04 or Debian 12 server into a hardened,
# production-ready host in one idempotent run.
#
#   Preview (changes nothing, no root needed):
#     ./bootstrap.sh --dry-run --user deploy --ssh-key-file ~/.ssh/id_ed25519.pub
#   Apply:
#     sudo ./bootstrap.sh --user deploy --ssh-key-file ./id_ed25519.pub
#
# Exit codes: 0 ok · 1 runtime error · 2 usage error · 3 safety refusal · 4 unsupported OS

set -Eeuo pipefail

readonly VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
TEMPLATE_DIR="${TEMPLATE_DIR:-$SCRIPT_DIR/templates}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"
# Treat every "is this already done?" probe as "no" so a dry run previews a
# brand-new server regardless of the machine it runs on. Used by the tests.
ASSUME_FRESH="${BOOTSTRAP_ASSUME_FRESH:-0}"

# ---------------------------------------------------------------------------
# Settings: defaults < --config file < command-line flags
# ---------------------------------------------------------------------------
DRY_RUN=0
ADMIN_USER=""
SSH_KEY_FILE=""
SSH_KEY_URL=""
SSH_PORT="22"
ALLOW_PASSWORD_AUTH=0
EXTRA_PORTS=""
TIMEZONE="UTC"
SWAP_SIZE="auto"
INSTALL_NGINX=1
APP_PORT="8000"
DOMAIN=""
EMAIL=""
ENABLE_CERTBOT=0
INSTALL_DOCKER=0
APP_NAME=""
APP_CMD=""
APP_DIR=""
SKIP_UPGRADE=0
SKIP_OS_CHECK=0
LOG_FILE="/var/log/server-bootstrap.log"

OS_ID=""
OS_VERSION=""
OS_CODENAME=""
SSH_KEYS=""
KEYS_FROM_URL_PENDING=0
CURRENT_STEP="preflight"
SUMMARY=()

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] [INFO] %s\n' "$(ts)" "$*"; }
ok()   { printf '[%s] [ OK ] %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] [WARN] %s\n' "$(ts)" "$*" >&2; }
die()  { printf '[%s] [FAIL] %s\n' "$(ts)" "$1" >&2; exit "${2:-1}"; }
step() { CURRENT_STEP="$*"; printf '\n[%s] ▸ %s\n' "$(ts)" "$*"; }
done_item() { SUMMARY+=("$*"); }

on_error() {
  local rc=$1 line=$2 cmd=$3
  printf '[%s] [FAIL] step "%s" failed (exit %s) at line %s: %s\n' \
    "$(ts)" "$CURRENT_STEP" "$rc" "$line" "$cmd" >&2
  printf '[%s] [FAIL] Nothing after this step was applied. Fix the cause and re-run; finished steps are skipped.\n' "$(ts)" >&2
  exit "$rc"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# Print a command the way you would type it.
quote_cmd() {
  local out="" arg
  for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then
      out+="$arg "
    else
      out+="'${arg//\'/\'\\\'\'}' "
    fi
  done
  printf '%s' "${out% }"
}

# Run a command, or only print it in --dry-run mode.
run() {
  if (( DRY_RUN )); then
    printf '  [dry-run] %s\n' "$(quote_cmd "$@")"
  else
    "$@"
  fi
}

# Run a shell snippet (pipes, redirects), or only print it in --dry-run mode.
run_sh() {
  if (( DRY_RUN )); then
    printf '  [dry-run] %s\n' "$1"
  else
    bash -c "$1"
  fi
}

# write_file PATH MODE [OWNER]  - content comes from stdin. Unchanged files are left alone.
write_file() {
  local path=$1 mode=$2 owner=${3:-root:root} content tmp
  content="$(cat)"
  if (( DRY_RUN )); then
    printf '  [dry-run] write %s (mode %s, owner %s)\n' "$path" "$mode" "$owner"
    printf '%s\n' "$content" | sed 's/^/  [dry-run]   | /'
    return 0
  fi
  if [[ -f "$path" && "$(cat "$path")" == "$content" ]]; then
    log "unchanged: $path"
    return 0
  fi
  install -d -m 0755 "$(dirname "$path")"
  tmp="$(mktemp)"
  printf '%s\n' "$content" > "$tmp"
  install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path"
  rm -f "$tmp"
  ok "wrote $path"
}

# render_template NAME KEY=value...  - replaces {{KEY}} placeholders.
render_template() {
  local file="$TEMPLATE_DIR/$1" content pair key val
  shift
  [[ -r "$file" ]] || die "template not found: $file (run from a full checkout of the repo)" 1
  content="$(<"$file")"
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    content="${content//"{{${key}}}"/"$val"}"
  done
  if [[ "$content" =~ \{\{[A-Z_]+\}\} ]]; then
    die "template $(basename "$file") has an unfilled placeholder: ${BASH_REMATCH[0]}" 1
  fi
  printf '%s\n' "$content"
}

fresh() { (( ASSUME_FRESH )); }

# ---------------------------------------------------------------------------
# Usage and argument parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
linux-server-bootstrap $VERSION
Harden and prepare a fresh Ubuntu 22.04/24.04 or Debian 12 server.

Usage: sudo ./bootstrap.sh --user NAME (--ssh-key-file FILE | --ssh-key-url URL) [options]
       ./bootstrap.sh --dry-run ...      print every command, change nothing

Required
  -u, --user NAME            admin account to create (sudo, key-only SSH)
  -k, --ssh-key-file FILE    public key(s) to authorize for that user
  -K, --ssh-key-url URL      fetch public keys, e.g. https://github.com/NAME.keys

SSH and firewall
  -p, --ssh-port PORT        SSH port (default 22)
      --allow-password-auth  keep SSH password login enabled (not recommended)
      --open-ports LIST      extra ports to open, e.g. 3000,5432/tcp,6000:6010/udp

System
      --timezone ZONE        e.g. Asia/Karachi (default UTC)
      --swap SIZE            auto | 0 | 2G | 512M (default auto, sized from RAM)
      --skip-upgrade         do not run apt-get upgrade
      --skip-os-check        run on an untested distribution

Web
      --no-nginx             do not install Nginx (ports 80/443 stay closed)
      --app-port PORT        port your app listens on behind Nginx (default 8000)
      --domain NAME          server_name for Nginx and the TLS certificate
      --certbot              get a Let's Encrypt certificate (needs --domain, --email)
      --email ADDRESS        Let's Encrypt account e-mail

Extras
      --docker               install Docker Engine + Compose plugin
      --app-name NAME        create a systemd service for your app
      --app-cmd "CMD"        ExecStart command for that service
      --app-dir DIR          working directory (default /home/USER/NAME)

Other
  -c, --config FILE          read settings from FILE (see server.conf.example)
  -n, --dry-run              print every command instead of running it
      --log-file FILE        default /var/log/server-bootstrap.log
  -h, --help                 show this help
  -V, --version              print version
EOF
}

opt_val() {
  if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
    die "option $1 needs a value (see --help)" 2
  fi
}

parse_args() {
  while (( $# )); do
    case "$1" in
      -n|--dry-run)          DRY_RUN=1 ;;
      -c|--config)           opt_val "$@"; shift ;;   # loaded earlier in main()
      -u|--user)             opt_val "$@"; ADMIN_USER=$2; shift ;;
      -k|--ssh-key-file)     opt_val "$@"; SSH_KEY_FILE=$2; shift ;;
      -K|--ssh-key-url)      opt_val "$@"; SSH_KEY_URL=$2; shift ;;
      -p|--ssh-port)         opt_val "$@"; SSH_PORT=$2; shift ;;
      --allow-password-auth) ALLOW_PASSWORD_AUTH=1 ;;
      --open-ports)          opt_val "$@"; EXTRA_PORTS=$2; shift ;;
      --timezone)            opt_val "$@"; TIMEZONE=$2; shift ;;
      --swap)                opt_val "$@"; SWAP_SIZE=$2; shift ;;
      --skip-upgrade)        SKIP_UPGRADE=1 ;;
      --skip-os-check)       SKIP_OS_CHECK=1 ;;
      --no-nginx)            INSTALL_NGINX=0 ;;
      --app-port)            opt_val "$@"; APP_PORT=$2; shift ;;
      --domain)              opt_val "$@"; DOMAIN=$2; shift ;;
      --email)               opt_val "$@"; EMAIL=$2; shift ;;
      --certbot)             ENABLE_CERTBOT=1 ;;
      --docker)              INSTALL_DOCKER=1 ;;
      --app-name)            opt_val "$@"; APP_NAME=$2; shift ;;
      --app-cmd)             opt_val "$@"; APP_CMD=$2; shift ;;
      --app-dir)             opt_val "$@"; APP_DIR=$2; shift ;;
      --log-file)            opt_val "$@"; LOG_FILE=$2; shift ;;
      -h|--help)             usage; exit 0 ;;
      -V|--version)          printf '%s\n' "$VERSION"; exit 0 ;;
      *)                     die "unknown option: $1 (see --help)" 2 ;;
    esac
    shift
  done
}

to_bool() {
  case "${1,,}" in
    1|yes|true|on)  printf '1' ;;
    0|no|false|off) printf '0' ;;
    *) return 1 ;;
  esac
}

# KEY=value file. Parsed, never sourced, so a config file cannot run code.
load_config() {
  local file=$1 line key val n=0
  [[ -r "$file" ]] || die "cannot read config file: $file" 2
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=(.*)$ ]]; then
      die "$file:$n: expected KEY=value" 2
    fi
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then
      val=${BASH_REMATCH[1]}
    fi
    case "$key" in
      ADMIN_USER|SSH_KEY_FILE|SSH_KEY_URL|SSH_PORT|EXTRA_PORTS|TIMEZONE|SWAP_SIZE|\
      APP_PORT|DOMAIN|EMAIL|APP_NAME|APP_CMD|APP_DIR|LOG_FILE)
        printf -v "$key" '%s' "$val" ;;
      ALLOW_PASSWORD_AUTH|INSTALL_NGINX|ENABLE_CERTBOT|INSTALL_DOCKER|SKIP_UPGRADE)
        to_bool "$val" >/dev/null || die "$file:$n: $key must be yes or no" 2
        printf -v "$key" '%s' "$(to_bool "$val")" ;;
      *)
        die "$file:$n: unknown setting '$key'" 2 ;;
    esac
  done < "$file"
}

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------
user_exists() { ! fresh && id -u "$ADMIN_USER" >/dev/null 2>&1; }

user_home() {
  local home=""
  if user_exists; then
    home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  fi
  printf '%s' "${home:-/home/$ADMIN_USER}"
}

pkg_installed() {
  ! fresh && dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

is_ssh_key() {
  [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]].*)?$ ]]
}

# Keys already authorized for the admin user, one per line (empty if none).
existing_keys() {
  local file
  file="$(user_home)/.ssh/authorized_keys"
  if ! fresh && [[ -r "$file" ]]; then
    grep -E '^(ssh-|ecdsa-|sk-)' "$file" || true
  fi
}

user_has_password() {
  user_exists && [[ "$(passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}')" == "P" ]]
}

# Can the admin user log in over SSH once hardening is applied?
admin_can_login() {
  [[ -n "$SSH_KEYS" ]] && return 0
  (( KEYS_FROM_URL_PENDING )) && return 0
  [[ -n "$(existing_keys)" ]] && return 0
  (( ALLOW_PASSWORD_AUTH )) && user_has_password && return 0
  return 1
}

ssh_socket_activated() {
  if fresh; then
    [[ "$OS_ID" == ubuntu && "$OS_VERSION" != 22.04 ]]
  else
    systemctl is-enabled ssh.socket >/dev/null 2>&1
  fi
}

ram_mb() { awk '/^MemTotal:/ {printf "%d", $2 / 1024}' "$MEMINFO_FILE"; }

swap_active() { ! fresh && [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; }

# auto: up to 2 GB RAM -> 2x RAM, up to 8 GB -> same as RAM, above that -> 4 GB
auto_swap_size() {
  local mb size_mb
  mb="$(ram_mb)"
  if (( mb <= 2048 )); then
    size_mb=$((mb * 2))
  elif (( mb <= 8192 )); then
    size_mb=$mb
  else
    size_mb=4096
  fi
  printf '%sG' "$(((size_mb + 1023) / 1024))"
}

# ---------------------------------------------------------------------------
# Preflight: every check runs before anything is changed
# ---------------------------------------------------------------------------
detect_os() {
  local key val
  [[ -r "$OS_RELEASE_FILE" ]] || die "cannot read $OS_RELEASE_FILE" 4
  while IFS='=' read -r key val; do
    val="${val%\"}"
    val="${val#\"}"
    case "$key" in
      ID) OS_ID=$val ;;
      VERSION_ID) OS_VERSION=$val ;;
      VERSION_CODENAME) OS_CODENAME=$val ;;
    esac
  done < "$OS_RELEASE_FILE"
  case "$OS_ID:$OS_VERSION" in
    ubuntu:22.04|ubuntu:24.04|debian:12) log "OS: $OS_ID $OS_VERSION ($OS_CODENAME)" ;;
    *)
      if (( SKIP_OS_CHECK )); then
        warn "untested OS ${OS_ID:-unknown} ${OS_VERSION:-?} - continuing because of --skip-os-check"
      else
        die "unsupported OS: ${OS_ID:-unknown} ${OS_VERSION:-?} (supported: Ubuntu 22.04/24.04, Debian 12; override with --skip-os-check)" 4
      fi ;;
  esac
}

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

collect_keys() {
  local line content=""
  if [[ -n "$SSH_KEY_FILE" ]]; then
    [[ -r "$SSH_KEY_FILE" ]] || die "cannot read SSH key file: $SSH_KEY_FILE" 2
    content="$(cat "$SSH_KEY_FILE")"
  fi
  if [[ -n "$SSH_KEY_URL" ]]; then
    [[ "$SSH_KEY_URL" =~ ^https:// ]] || die "--ssh-key-url must be an https:// URL" 2
    if (( DRY_RUN )); then
      KEYS_FROM_URL_PENDING=1
      log "keys from $SSH_KEY_URL are downloaded and validated during a real run"
    else
      content+=$'\n'"$(curl -fsSL --max-time 20 "$SSH_KEY_URL")" \
        || die "could not download SSH keys from $SSH_KEY_URL" 1
    fi
  fi
  if [[ "$content" == *"PRIVATE KEY"* ]]; then
    die "that is a PRIVATE key. Pass the public key (the .pub file) and keep the private key on your own machine." 3
  fi
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    is_ssh_key "$line" || die "does not look like an SSH public key: ${line:0:40}..." 3
    SSH_KEYS+="$line"$'\n'
  done <<< "$content"
  SSH_KEYS="${SSH_KEYS%$'\n'}"
  if [[ -n "$SSH_KEY_URL" && $DRY_RUN -eq 0 && -z "$SSH_KEYS" ]]; then
    die "no public keys found at $SSH_KEY_URL" 3
  fi
}

preflight() {
  step "Preflight checks"
  if (( DRY_RUN )); then
    log "DRY RUN - nothing will be changed; every command is printed instead of run"
  elif (( EUID != 0 )); then
    die "run as root (sudo ./bootstrap.sh ...), or add --dry-run to preview" 1
  fi

  [[ -n "$ADMIN_USER" ]] || die "--user is required (the admin account to create)" 2
  [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid username: $ADMIN_USER" 2
  [[ "$ADMIN_USER" != root ]] || die "--user must not be root" 2
  valid_port "$SSH_PORT" || die "invalid SSH port: $SSH_PORT" 2
  valid_port "$APP_PORT" || die "invalid app port: $APP_PORT" 2

  local p
  if [[ -n "$EXTRA_PORTS" ]]; then
    for p in ${EXTRA_PORTS//,/ }; do
      [[ "$p" =~ ^[0-9]{1,5}(:[0-9]{1,5})?(/(tcp|udp))?$ ]] || die "invalid port in --open-ports: $p" 2
    done
  fi
  [[ "$SWAP_SIZE" =~ ^(auto|0|[1-9][0-9]*[MG])$ ]] || die "invalid --swap value: $SWAP_SIZE (auto, 0, 2G, 512M)" 2
  if [[ -d /usr/share/zoneinfo && ! -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    die "unknown timezone: $TIMEZONE" 2
  fi
  if [[ -n "$DOMAIN" && ! "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; then
    die "invalid domain: $DOMAIN" 2
  fi
  if (( ENABLE_CERTBOT )); then
    (( INSTALL_NGINX )) || die "--certbot needs Nginx (remove --no-nginx)" 2
    [[ -n "$DOMAIN" ]] || die "--certbot needs --domain" 2
    [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "--certbot needs a valid --email" 2
  fi
  if [[ -n "$APP_NAME" || -n "$APP_CMD" ]]; then
    [[ "$APP_NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "--app-name must be lowercase letters, digits and dashes" 2
    [[ "$APP_CMD" == /* ]] || die "--app-cmd must start with an absolute path, e.g. /usr/bin/python3 app.py" 2
    APP_DIR="${APP_DIR:-/home/$ADMIN_USER/$APP_NAME}"
  fi

  detect_os
  collect_keys

  # Lock-out guard: never disable password/root login unless the admin user
  # will be able to log in afterwards.
  if ! admin_can_login; then
    if (( ALLOW_PASSWORD_AUTH )); then
      die "Refusing to continue: '$ADMIN_USER' would have no SSH key and no password, so nobody could log in once root login is disabled. Pass --ssh-key-file or --ssh-key-url, or set a password first (passwd $ADMIN_USER)." 3
    fi
    die "Refusing to disable SSH password login: '$ADMIN_USER' has no authorized SSH key, so you would be locked out. Pass --ssh-key-file or --ssh-key-url (or --allow-password-auth to keep password login)." 3
  fi
  ok "preflight passed"
}

setup_logging() {
  (( DRY_RUN )) && return 0
  install -d -m 0755 "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 0640 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "linux-server-bootstrap $VERSION - logging to $LOG_FILE"
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
apt_install() {
  local pkg missing=()
  for pkg in "$@"; do
    pkg_installed "$pkg" || missing+=("$pkg")
  done
  if (( ${#missing[@]} == 0 )); then
    log "already installed: $*"
    return 0
  fi
  run apt-get install -y --no-install-recommends "${missing[@]}"
}

step_packages() {
  step "System packages and automatic security updates"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  run apt-get update -q
  if (( SKIP_UPGRADE )); then
    log "skipping apt-get upgrade (--skip-upgrade)"
  else
    run apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  fi
  apt_install sudo ca-certificates curl gnupg ufw fail2ban python3-systemd unattended-upgrades
  render_template 20auto-upgrades | write_file /etc/apt/apt.conf.d/20auto-upgrades 0644
  run systemctl enable --now unattended-upgrades
  done_item "Packages updated; unattended security upgrades enabled"
}

step_timezone() {
  step "Timezone and time sync"
  local current=""
  fresh || current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [[ "$current" == "$TIMEZONE" ]]; then
    log "timezone already $TIMEZONE"
  else
    run timedatectl set-timezone "$TIMEZONE"
  fi
  run timedatectl set-ntp true
  done_item "Timezone $TIMEZONE, NTP sync on"
}

step_swap() {
  step "Swap"
  local size="$SWAP_SIZE"
  if [[ "$size" == 0 ]]; then
    log "swap disabled by --swap 0"
    return 0
  fi
  if swap_active; then
    log "swap already active - leaving it as is"
    done_item "Swap: existing swap kept"
    return 0
  fi
  [[ "$size" == auto ]] && size="$(auto_swap_size)"
  log "RAM $(ram_mb) MB -> swap file $size"
  if (( ! DRY_RUN )); then
    local need_mb avail_mb
    need_mb=$(( ${size%[MG]} * $([[ "$size" == *G ]] && echo 1024 || echo 1) ))
    avail_mb="$(df --output=avail -BM / | tail -1 | tr -dc '0-9')"
    if (( avail_mb < need_mb + 1024 )); then
      warn "only ${avail_mb} MB free on / - skipping the ${size} swap file"
      return 0
    fi
  fi
  run fallocate -l "$size" /swapfile
  run chmod 600 /swapfile
  run mkswap /swapfile
  run swapon /swapfile
  if fresh || ! grep -q '^/swapfile ' /etc/fstab 2>/dev/null; then
    run_sh "echo '/swapfile none swap sw 0 0' >> /etc/fstab"
  fi
  printf 'vm.swappiness = 10\n' | write_file /etc/sysctl.d/99-swappiness.conf 0644
  run sysctl -p /etc/sysctl.d/99-swappiness.conf
  done_item "Swap file $size (swappiness 10)"
}

append_key() {
  local file=$1 key=$2 short
  short="$(awk '{print $1, substr($2, 1, 12) "...", $3}' <<< "$key")"
  if (( DRY_RUN )); then
    printf '  [dry-run] authorize key %s in %s\n' "$short" "$file"
    return 0
  fi
  if grep -qxF -- "$key" "$file" 2>/dev/null; then
    log "key already authorized: $short"
  else
    printf '%s\n' "$key" >> "$file"
    ok "authorized key: $short"
  fi
}

step_user() {
  step "Admin user '$ADMIN_USER'"
  if user_exists; then
    log "user $ADMIN_USER already exists"
  else
    run adduser --disabled-password --gecos "" "$ADMIN_USER"
  fi
  run usermod -aG sudo "$ADMIN_USER"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" \
    | write_file "/etc/sudoers.d/90-$ADMIN_USER" 0440
  run visudo -cf "/etc/sudoers.d/90-$ADMIN_USER"

  local home ssh_dir key
  home="$(user_home)"
  ssh_dir="$home/.ssh"
  run install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ssh_dir"
  if (( KEYS_FROM_URL_PENDING )); then
    printf '  [dry-run] curl -fsSL %s  (each key validated, then authorized)\n' "$SSH_KEY_URL"
  fi
  if [[ -n "$SSH_KEYS" ]]; then
    (( DRY_RUN )) || touch "$ssh_dir/authorized_keys"
    while IFS= read -r key; do
      append_key "$ssh_dir/authorized_keys" "$key"
    done <<< "$SSH_KEYS"
  fi
  if (( DRY_RUN )) || [[ -f "$ssh_dir/authorized_keys" ]]; then
    run chmod 600 "$ssh_dir/authorized_keys"
  fi
  run chown -R "$ADMIN_USER:$ADMIN_USER" "$ssh_dir"

  local n keys_desc
  n="$(grep -c . <<< "$SSH_KEYS" || true)"
  keys_desc="$n SSH key(s)"
  (( KEYS_FROM_URL_PENDING )) && keys_desc="keys from $SSH_KEY_URL"
  done_item "Admin user $ADMIN_USER: sudo, $keys_desc"
}

step_firewall() {
  step "Firewall (UFW)"
  local p rule opened=("${SSH_PORT}/tcp")
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw limit "${SSH_PORT}/tcp" comment SSH
  if [[ "$SSH_PORT" != 22 ]]; then
    # Keep 22 reachable until the new port is proven to work.
    run ufw limit 22/tcp comment 'SSH - remove after testing the new port'
    opened+=("22/tcp (temporary)")
  fi
  if (( INSTALL_NGINX )); then
    run ufw allow 80/tcp comment HTTP
    run ufw allow 443/tcp comment HTTPS
    opened+=("80/tcp" "443/tcp")
  fi
  if [[ -n "$EXTRA_PORTS" ]]; then
    for p in ${EXTRA_PORTS//,/ }; do
      rule="$p"
      [[ "$rule" == */* ]] || rule="$rule/tcp"
      run ufw allow "$rule" comment custom
      opened+=("$rule")
    done
  fi
  run ufw --force enable
  done_item "Firewall on: deny incoming, open ${opened[*]}"
}

step_ssh() {
  step "SSH hardening"
  local dropin=/etc/ssh/sshd_config.d/10-hardening.conf pw=no ports
  (( ALLOW_PASSWORD_AUTH )) && pw=yes

  # Second lock-out guard: read the authorized_keys file that is now on disk.
  if (( ! DRY_RUN )) && [[ -z "$(existing_keys)" ]] && ! { (( ALLOW_PASSWORD_AUTH )) && user_has_password; }; then
    die "Refusing to harden SSH: $(user_home)/.ssh/authorized_keys has no valid key for $ADMIN_USER" 3
  fi

  run cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
  # Ubuntu 22.04+ and Debian 12 ship this Include line; older or edited configs may not.
  if ! fresh && ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
    run sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi
  render_template sshd-hardening.conf \
    "SSH_PORT=$SSH_PORT" "PASSWORD_AUTH=$pw" "ADMIN_USER=$ADMIN_USER" \
    | write_file "$dropin" 0644

  # Validate before reloading; a broken config is rolled back, never applied.
  if (( DRY_RUN )); then
    run sshd -t
  elif ! sshd -t; then
    rm -f "$dropin"
    die "sshd -t rejected the new config - it was removed and SSH was not reloaded" 1
  fi

  # Ubuntu 22.10+ starts sshd from ssh.socket, and systemd derives the socket from the Port
  # setting, so after a port change systemd must reload and restart the socket.
  if ssh_socket_activated; then
    run systemctl daemon-reload
    run systemctl restart ssh.socket
    run systemctl try-reload-or-restart ssh
  else
    run systemctl reload-or-restart ssh
  fi
  if (( ! DRY_RUN )); then
    local effective
    effective="$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')"
    [[ "$effective" == "$pw" ]] || warn "sshd reports PasswordAuthentication=$effective (expected $pw) - check other files in /etc/ssh/sshd_config.d/"
  fi

  ports="$SSH_PORT"
  [[ "$SSH_PORT" != 22 ]] && ports="$SSH_PORT and 22 (temporary)"
  done_item "SSH on port $ports: root login off, password login $([[ $pw == no ]] && echo off || echo ON), only $ADMIN_USER allowed"
}

step_fail2ban() {
  step "Fail2ban"
  local ports="$SSH_PORT"
  [[ "$SSH_PORT" != 22 ]] && ports="$SSH_PORT,22"
  render_template fail2ban-sshd.local "SSH_PORTS=$ports" \
    | write_file /etc/fail2ban/jail.d/sshd.local 0644
  run systemctl enable fail2ban
  run systemctl restart fail2ban
  done_item "Fail2ban sshd jail: 5 tries / 10 min -> 1 h ban, longer for repeat offenders"
}

step_nginx() {
  (( INSTALL_NGINX )) || return 0
  step "Nginx reverse proxy"
  local site="${DOMAIN:-default-app}" server_name="${DOMAIN:-_}"
  apt_install nginx
  render_template nginx-common.conf | write_file /etc/nginx/conf.d/00-common.conf 0644
  render_template nginx-site.conf "SERVER_NAME=$server_name" "APP_PORT=$APP_PORT" \
    | write_file "/etc/nginx/sites-available/$site.conf" 0644
  run ln -sfn "/etc/nginx/sites-available/$site.conf" "/etc/nginx/sites-enabled/$site.conf"
  run rm -f /etc/nginx/sites-enabled/default
  run nginx -t
  run systemctl enable nginx
  run systemctl reload-or-restart nginx
  done_item "Nginx: $server_name -> 127.0.0.1:$APP_PORT"
}

step_certbot() {
  (( ENABLE_CERTBOT )) || return 0
  step "TLS certificate (Let's Encrypt)"
  if ! fresh && [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    log "certificate for $DOMAIN already present - renewal is handled by certbot.timer"
  else
    apt_install certbot python3-certbot-nginx
    run certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect
  fi
  run systemctl enable --now certbot.timer
  done_item "HTTPS for $DOMAIN, auto-renewal via certbot.timer"
}

step_docker() {
  (( INSTALL_DOCKER )) || return 0
  step "Docker Engine"
  if ! fresh && command -v docker >/dev/null 2>&1; then
    log "docker already installed: $(docker --version)"
  else
    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture 2>/dev/null || echo amd64)" "$OS_ID" "${OS_CODENAME:-stable}" \
      | write_file /etc/apt/sources.list.d/docker.list 0644
    run apt-get update -q
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  run usermod -aG docker "$ADMIN_USER"
  run systemctl enable --now docker
  done_item "Docker + Compose; $ADMIN_USER in the docker group"
}

step_app() {
  [[ -n "$APP_NAME" ]] || return 0
  step "systemd service '$APP_NAME'"
  run install -d -m 0755 -o "$ADMIN_USER" -g "$ADMIN_USER" "$APP_DIR"
  render_template app.service "APP_NAME=$APP_NAME" "APP_USER=$ADMIN_USER" \
    "APP_DIR=$APP_DIR" "APP_CMD=$APP_CMD" \
    | write_file "/etc/systemd/system/$APP_NAME.service" 0644
  run systemctl daemon-reload
  run systemctl enable "$APP_NAME"
  done_item "Service $APP_NAME (restart on failure) - deploy to $APP_DIR, then: sudo systemctl start $APP_NAME"
}

step_healthcheck() {
  step "Health check command"
  run install -m 0755 "$SCRIPT_DIR/healthcheck.sh" /usr/local/bin/server-healthcheck
  done_item "Run 'sudo server-healthcheck' any time for a status report"
}

summary() {
  local item ip="<server-ip>"
  if (( ! DRY_RUN )); then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    ip="${ip:-<server-ip>}"
  fi
  printf '\n────────────────────────────────────────────────────────────\n'
  if (( DRY_RUN )); then
    printf ' DRY RUN COMPLETE - this is what a real run would set up\n'
  else
    printf ' SERVER READY\n'
  fi
  printf '────────────────────────────────────────────────────────────\n'
  for item in "${SUMMARY[@]}"; do
    printf '  ✓ %s\n' "$item"
  done
  printf '\n  ▸ Before closing this session, open a NEW terminal and check:\n'
  printf '      ssh -p %s %s@%s\n' "$SSH_PORT" "$ADMIN_USER" "$ip"
  if [[ "$SSH_PORT" != 22 ]]; then
    printf '  ▸ When that works, close the temporary port:  sudo ufw delete limit 22/tcp\n'
  fi
  if (( INSTALL_DOCKER )); then
    printf '  ▸ Docker publishes ports past UFW. Bind containers to 127.0.0.1 and let Nginx proxy them.\n'
  fi
  (( DRY_RUN )) || printf '  ▸ Full log: %s\n' "$LOG_FILE"
}

main() {
  local args=("$@") i
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
      -h|--help) usage; exit 0 ;;
      -c|--config)
        (( i + 1 < ${#args[@]} )) || die "option ${args[i]} needs a value" 2
        load_config "${args[i + 1]}" ;;
    esac
  done
  parse_args "$@"

  preflight
  setup_logging
  step_packages
  step_timezone
  step_swap
  step_user
  step_firewall
  step_ssh
  step_fail2ban
  step_nginx
  step_certbot
  step_docker
  step_app
  step_healthcheck
  summary
}

main "$@"
