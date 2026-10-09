#!/usr/bin/env bash
#
# Test suite for bootstrap.sh and healthcheck.sh.
# Every bootstrap run here uses --dry-run with fixture files, so nothing on the
# machine running the tests is changed. Refuses to run as root as a safeguard.
#
#   bash tests/run_tests.sh

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
BOOT="$ROOT/bootstrap.sh"
HEALTH="$ROOT/healthcheck.sh"

if (( EUID == 0 )); then
  echo "Refusing to run the tests as root. Run them as a normal user." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
OUT=""
RC=0
ERRORS=()

# boot ARGS...  run bootstrap.sh against a simulated fresh server
boot() {
  OUT="$(BOOTSTRAP_ASSUME_FRESH=1 \
    OS_RELEASE_FILE="${OSR:-$FIX/os-release-ubuntu-24.04}" \
    MEMINFO_FILE="${MEM:-$FIX/meminfo-1g}" \
    bash "$BOOT" "$@" 2>&1)"
  RC=$?
}

KEY=(--ssh-key-file "$FIX/id_ed25519.pub")
BASE=(--dry-run --user deploy "${KEY[@]}")

fail_check() { ERRORS+=("$1"); }

expect_rc()  { [[ "$RC" == "$1" ]] || fail_check "exit code $RC, expected $1"; }
expect_has() { grep -qF -- "$1" <<< "$OUT" || fail_check "missing: $1"; }
expect_not() { ! grep -qF -- "$1" <<< "$OUT" || fail_check "unexpected: $1"; }

# expect_before A B: first line containing A comes before first line containing B
expect_before() {
  local a b
  a="$(grep -nF -- "$1" <<< "$OUT" | head -1 | cut -d: -f1)"
  b="$(grep -nF -- "$2" <<< "$OUT" | head -1 | cut -d: -f1)"
  if [[ -z "$a" || -z "$b" ]] || (( a >= b )); then
    fail_check "expected '$1' before '$2'"
  fi
}

# ---------------------------------------------------------------------------
# Usage and validation
# ---------------------------------------------------------------------------
test_help_and_version() {
  boot --help
  expect_rc 0
  expect_has "Usage: sudo ./bootstrap.sh"
  boot --version
  expect_rc 0
  expect_has "1.0.0"
}

test_unknown_option_is_usage_error() {
  boot --dry-run --user deploy --frobnicate
  expect_rc 2
  expect_has "unknown option: --frobnicate"
}

test_user_is_required() {
  boot --dry-run "${KEY[@]}"
  expect_rc 2
  expect_has "--user is required"
}

test_root_cannot_be_admin_user() {
  boot --dry-run --user root "${KEY[@]}"
  expect_rc 2
  expect_has "--user must not be root"
}

test_invalid_ports_rejected() {
  boot "${BASE[@]}" --ssh-port 70000
  expect_rc 2
  expect_has "invalid SSH port"
  boot "${BASE[@]}" --open-ports "3000,http"
  expect_rc 2
  expect_has "invalid port in --open-ports: http"
}

test_real_run_requires_root() {
  # Without --dry-run the script must stop at the root check, before any change.
  boot --user deploy "${KEY[@]}"
  expect_rc 1
  expect_has "run as root"
  expect_not "apt-get"
}

# ---------------------------------------------------------------------------
# Lock-out protection
# ---------------------------------------------------------------------------
test_refuses_to_disable_passwords_without_key() {
  boot --dry-run --user deploy
  expect_rc 3
  expect_has "Refusing to disable SSH password login"
  expect_not "[dry-run]"
}

test_refuses_password_mode_when_nobody_could_log_in() {
  boot --dry-run --user deploy --allow-password-auth
  expect_rc 3
  expect_has "nobody could log in"
}

test_rejects_text_that_is_not_a_key() {
  boot --dry-run --user deploy --ssh-key-file "$FIX/not_a_key.txt"
  expect_rc 3
  expect_has "does not look like an SSH public key"
  expect_not "[dry-run]"
}

test_rejects_private_key() {
  local priv="$TMP/id_test"
  printf -- '-----BEGIN %s PRIVATE KEY-----\nAAAA\n-----END %s PRIVATE KEY-----\n' OPENSSH OPENSSH > "$priv"
  boot --dry-run --user deploy --ssh-key-file "$priv"
  expect_rc 3
  expect_has "that is a PRIVATE key"
}

test_key_url_must_be_https() {
  boot --dry-run --user deploy --ssh-key-url "http://example.com/keys"
  expect_rc 2
  expect_has "must be an https:// URL"
}

test_key_url_accepted_in_dry_run() {
  boot --dry-run --user deploy --ssh-key-url "https://github.com/octocat.keys"
  expect_rc 0
  expect_has "curl -fsSL https://github.com/octocat.keys"
  expect_has "PasswordAuthentication no"
}

# ---------------------------------------------------------------------------
# Default run
# ---------------------------------------------------------------------------
test_full_default_run() {
  boot "${BASE[@]}"
  expect_rc 0
  expect_has "apt-get update"
  expect_has "unattended-upgrades"
  expect_has "APT::Periodic::Unattended-Upgrade \"1\";"
  expect_has "adduser --disabled-password --gecos '' deploy"
  expect_has "usermod -aG sudo deploy"
  expect_has "visudo -cf /etc/sudoers.d/90-deploy"
  expect_has "authorize key ssh-ed25519"
  expect_has "PermitRootLogin no"
  expect_has "PasswordAuthentication no"
  expect_has "AllowUsers deploy"
  expect_has "sshd -t"
  expect_has "ufw default deny incoming"
  expect_has "ufw limit 22/tcp"
  expect_has "ufw allow 80/tcp"
  expect_has "ufw allow 443/tcp"
  expect_has "backend  = systemd"
  expect_has "timedatectl set-timezone UTC"
  expect_has "timedatectl set-ntp true"
  expect_has "proxy_pass http://127.0.0.1:8000;"
  expect_has "nginx -t"
  expect_has "DRY RUN COMPLETE"
  expect_not "docker"
  expect_not "certbot"
}

test_steps_run_in_safe_order() {
  boot "${BASE[@]}"
  expect_before "authorize key" "write /etc/ssh/sshd_config.d/10-hardening.conf"
  expect_before "ufw limit 22/tcp" "ufw --force enable"
  expect_before "sshd -t" "systemctl restart ssh.socket"
  expect_before "ufw --force enable" "write /etc/ssh/sshd_config.d/10-hardening.conf"
  expect_before "nginx -t" "systemctl reload-or-restart nginx"
}

test_dry_run_does_not_touch_the_system() {
  local marker="$TMP/should-not-exist.log"
  boot "${BASE[@]}" --log-file "$marker"
  expect_rc 0
  [[ ! -e "$marker" ]] || fail_check "dry run created the log file"
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
test_custom_ssh_port_keeps_22_open_temporarily() {
  boot "${BASE[@]}" --ssh-port 2222
  expect_rc 0
  expect_has "Port 2222"
  expect_has "ufw limit 2222/tcp"
  expect_has "ufw limit 22/tcp comment 'SSH - remove after testing the new port'"
  expect_has "port     = 2222,22"
  expect_has "sudo ufw delete limit 22/tcp"
  expect_before "ufw limit 2222/tcp" "systemctl restart ssh.socket"
}

test_allow_password_auth_with_key() {
  boot "${BASE[@]}" --allow-password-auth
  expect_rc 0
  expect_has "PasswordAuthentication yes"
  expect_not "PasswordAuthentication no"
  expect_has "PermitRootLogin no"
}

test_extra_ports() {
  boot "${BASE[@]}" --open-ports "3000,5432/tcp,60000:61000/udp"
  expect_rc 0
  expect_has "ufw allow 3000/tcp"
  expect_has "ufw allow 5432/tcp"
  expect_has "ufw allow 60000:61000/udp"
}

test_no_nginx_keeps_web_ports_closed() {
  boot "${BASE[@]}" --no-nginx
  expect_rc 0
  expect_not "ufw allow 80/tcp"
  expect_not "nginx"
}

test_certbot_requires_domain_and_email() {
  boot "${BASE[@]}" --certbot
  expect_rc 2
  expect_has "--certbot needs --domain"
  boot "${BASE[@]}" --certbot --domain example.com
  expect_rc 2
  expect_has "--certbot needs a valid --email"
}

test_certbot() {
  boot "${BASE[@]}" --certbot --domain example.com --email ops@example.com
  expect_rc 0
  expect_has "server_name example.com;"
  expect_has "certbot --nginx -d example.com --non-interactive --agree-tos -m ops@example.com --redirect"
  expect_has "systemctl enable --now certbot.timer"
  expect_before "nginx -t" "certbot --nginx"
}

test_docker() {
  boot "${BASE[@]}" --docker
  expect_rc 0
  expect_has "https://download.docker.com/linux/ubuntu noble stable"
  expect_has "docker-compose-plugin"
  expect_has "usermod -aG docker deploy"
  expect_has "Docker publishes ports past UFW"
}

test_docker_repo_follows_os() {
  OSR="$FIX/os-release-debian-12" boot "${BASE[@]}" --docker
  expect_rc 0
  expect_has "https://download.docker.com/linux/debian bookworm stable"
}

test_app_service() {
  boot "${BASE[@]}" --app-name api --app-cmd "/usr/bin/python3 -m uvicorn main:app --port 8000"
  expect_rc 0
  expect_has "write /etc/systemd/system/api.service"
  expect_has "ExecStart=/usr/bin/python3 -m uvicorn main:app --port 8000"
  expect_has "User=deploy"
  expect_has "WorkingDirectory=/home/deploy/api"
  expect_has "Restart=on-failure"
  expect_has "systemctl enable api"
}

test_app_cmd_needs_absolute_path() {
  boot "${BASE[@]}" --app-name api --app-cmd "python3 app.py"
  expect_rc 2
  expect_has "absolute path"
}

test_app_cmd_with_ampersand_renders_literally() {
  boot "${BASE[@]}" --app-name worker --app-cmd "/bin/sh -c 'a && b'"
  expect_rc 0
  expect_has "ExecStart=/bin/sh -c 'a && b'"
}

# ---------------------------------------------------------------------------
# Swap sizing and OS support
# ---------------------------------------------------------------------------
test_swap_sizing() {
  MEM="$FIX/meminfo-1g" boot "${BASE[@]}"
  expect_has "fallocate -l 2G /swapfile"
  MEM="$FIX/meminfo-4g" boot "${BASE[@]}"
  expect_has "fallocate -l 4G /swapfile"
  MEM="$FIX/meminfo-16g" boot "${BASE[@]}"
  expect_has "fallocate -l 4G /swapfile"
  boot "${BASE[@]}" --swap 0
  expect_not "fallocate"
  boot "${BASE[@]}" --swap 512M
  expect_has "fallocate -l 512M /swapfile"
  boot "${BASE[@]}" --swap lots
  expect_rc 2
}

test_supported_os_versions() {
  local f
  for f in os-release-ubuntu-22.04 os-release-ubuntu-24.04 os-release-debian-12; do
    OSR="$FIX/$f" boot "${BASE[@]}"
    [[ "$RC" == 0 ]] || fail_check "$f: exit $RC"
  done
}

test_ssh_socket_only_on_newer_ubuntu() {
  OSR="$FIX/os-release-ubuntu-22.04" boot "${BASE[@]}"
  expect_not "ssh.socket"
  expect_has "systemctl reload-or-restart ssh"
  OSR="$FIX/os-release-ubuntu-24.04" boot "${BASE[@]}"
  expect_has "systemctl restart ssh.socket"
}

test_unsupported_os() {
  OSR="$FIX/os-release-centos-9" boot "${BASE[@]}"
  expect_rc 4
  expect_has "unsupported OS: centos 9"
  OSR="$FIX/os-release-centos-9" boot "${BASE[@]}" --skip-os-check
  expect_rc 0
  expect_has "untested OS centos 9"
}

# ---------------------------------------------------------------------------
# Config file
# ---------------------------------------------------------------------------
test_config_file_and_flag_override() {
  local conf="$TMP/server.conf"
  cat > "$conf" <<EOF
# comment
ADMIN_USER=ops
SSH_KEY_FILE="$FIX/two_keys.pub"
SSH_PORT=2200
TIMEZONE=Europe/London
INSTALL_DOCKER=yes
APP_NAME=shop
APP_CMD=/usr/bin/node server.js
EOF
  boot --dry-run --config "$conf" --timezone Asia/Karachi
  expect_rc 0
  expect_has "adduser --disabled-password --gecos '' ops"
  expect_has "AllowUsers ops"
  expect_has "Port 2200"
  expect_has "timedatectl set-timezone Asia/Karachi"
  expect_not "Europe/London"
  expect_has "docker-ce"
  expect_has "ExecStart=/usr/bin/node server.js"
  expect_has "deploy@example.com"
  expect_has "ci@example.com"
  expect_has "2 SSH key(s)"
}

test_config_file_rejects_unknown_keys() {
  local conf="$TMP/bad.conf"
  printf 'ADMIN_USER=ops\nRM_RF=/\n' > "$conf"
  boot --dry-run --config "$conf"
  expect_rc 2
  expect_has "unknown setting 'RM_RF'"
}

test_config_file_is_not_executed() {
  local conf="$TMP/evil.conf" marker="$TMP/pwned"
  # The literal $(...) is the point of this test: it must never be executed.
  # shellcheck disable=SC2016
  printf 'ADMIN_USER=ops\nTIMEZONE=$(touch %s)\n' "$marker" > "$conf"
  boot --dry-run --config "$conf" "${KEY[@]}"
  [[ ! -e "$marker" ]] || fail_check "config file content was executed"
  expect_rc 2
}

# ---------------------------------------------------------------------------
# healthcheck.sh
# ---------------------------------------------------------------------------
test_healthcheck_runs_read_only() {
  OUT="$(bash "$HEALTH" --no-color 2>&1)"
  RC=$?
  [[ "$RC" == 0 || "$RC" == 1 ]] || fail_check "healthcheck exit $RC"
  expect_has "Server health:"
  expect_has "Resources"
  expect_has "disk /"
  expect_has "checks:"
}

test_healthcheck_usage() {
  OUT="$(bash "$HEALTH" --help 2>&1)"
  RC=$?
  expect_rc 0
  expect_has "Usage: server-healthcheck"
  OUT="$(bash "$HEALTH" --bogus 2>&1)"
  RC=$?
  expect_rc 2
}

# ---------------------------------------------------------------------------
main() {
  local t
  printf 'linux-server-bootstrap test suite\n\n'
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    ERRORS=()
    unset OSR MEM
    "$t"
    if (( ${#ERRORS[@]} == 0 )); then
      PASS=$((PASS + 1))
      printf '  ✓ %s\n' "${t#test_}"
    else
      FAIL=$((FAIL + 1))
      printf '  ✕ %s\n' "${t#test_}"
      printf '      - %s\n' "${ERRORS[@]}"
    fi
  done
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 ))
}

main "$@"
