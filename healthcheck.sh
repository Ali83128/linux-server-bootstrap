#!/usr/bin/env bash
#
# server-healthcheck - one-screen status report for a server set up by
# linux-server-bootstrap. Read-only: it never changes anything.
#
#   sudo server-healthcheck            full report (some checks need root)
#   server-healthcheck --services nginx,api,postgresql
#
# Exit code: 0 = no failures, 1 = at least one check failed, 2 = usage error.

set -uo pipefail

SERVICES="ssh nginx fail2ban docker"
DISK_WARN=80
DISK_FAIL=90
CERT_WARN_DAYS=30
CERT_FAIL_DAYS=14

FAILS=0
WARNS=0
CHECKS=0

usage() {
  cat <<'EOF'
server-healthcheck - read-only status report

Usage: server-healthcheck [--services LIST] [--no-color] [-h]

  --services LIST   extra systemd services to check, comma separated
  --no-color        plain output (also honoured: NO_COLOR=1)
  -h, --help        show this help
EOF
}

use_color=1
[[ -t 1 && -z "${NO_COLOR:-}" ]] || use_color=0

while (( $# )); do
  case "$1" in
    --services)
      [[ $# -ge 2 && -n "$2" ]] || { echo "--services needs a value" >&2; exit 2; }
      SERVICES="$SERVICES ${2//,/ }"
      shift ;;
    --no-color) use_color=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

if (( use_color )); then
  C_OK=$'\e[32m' C_WARN=$'\e[33m' C_FAIL=$'\e[31m' C_DIM=$'\e[2m' C_BOLD=$'\e[1m' C_OFF=$'\e[0m'
else
  C_OK='' C_WARN='' C_FAIL='' C_DIM='' C_BOLD='' C_OFF=''
fi

is_root() { (( EUID == 0 )); }

section() {
  printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"
}

# row STATUS NAME DETAIL   STATUS: ok | warn | fail | info
row() {
  local status=$1 name=$2 detail=$3 mark
  case "$status" in
    ok)   mark="${C_OK}✓${C_OFF}"; CHECKS=$((CHECKS + 1)) ;;
    warn) mark="${C_WARN}!${C_OFF}"; CHECKS=$((CHECKS + 1)); WARNS=$((WARNS + 1)) ;;
    fail) mark="${C_FAIL}✕${C_OFF}"; CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)) ;;
    *)    mark="${C_DIM}▸${C_OFF}" ;;
  esac
  printf '  %s  %-20s %s\n' "$mark" "$name" "$detail"
}

have() { command -v "$1" >/dev/null 2>&1; }

systemd_up() {
  have systemctl && [[ -d /run/systemd/system ]]
}

# ---------------------------------------------------------------------------
host="$(hostname 2>/dev/null || echo unknown)"
printf '%sServer health: %s%s   %s\n' "$C_BOLD" "$host" "$C_OFF" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
if [[ -r /etc/os-release ]]; then
  printf '%s%s, kernel %s, up %s%s\n' "$C_DIM" \
    "$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2}' /etc/os-release)" "$(uname -r)" \
    "$(uptime -p 2>/dev/null | sed 's/^up //')" "$C_OFF"
fi
is_root || printf '%sNot running as root: firewall, fail2ban and certificate checks are skipped.%s\n' "$C_DIM" "$C_OFF"

# ---------------------------------------------------------------------------
section "Services"
if systemd_up; then
  seen=" "
  for svc in $SERVICES; do
    [[ "$seen" == *" $svc "* ]] && continue
    seen+="$svc "
    if ! systemctl list-unit-files "$svc.service" --no-legend 2>/dev/null | grep -q .; then
      row info "$svc" "not installed"
      continue
    fi
    state="$(systemctl is-active "$svc" 2>/dev/null)"
    if [[ "$state" == active ]]; then
      since="$(systemctl show -p ActiveEnterTimestamp --value "$svc" 2>/dev/null)"
      row ok "$svc" "active${since:+ since $since}"
    elif [[ "$svc" == ssh ]] && systemctl is-active ssh.socket >/dev/null 2>&1; then
      row ok "$svc" "listening via ssh.socket"
    else
      row fail "$svc" "${state:-unknown}"
    fi
  done
  failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd, -)"
  if [[ -n "$failed_units" ]]; then
    row fail "failed units" "$failed_units"
  else
    row ok "failed units" "none"
  fi
else
  row info "systemd" "not available on this machine"
fi

# ---------------------------------------------------------------------------
section "Network"
if have ss; then
  listening="$(ss -Htln 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -nu | paste -sd' ' -)"
  public="$(ss -Htln 2>/dev/null | awk '{print $4}' \
    | grep -Ev '^(127\.|\[::1\]|::1|\[?fe80)' | sed -E 's/.*:([0-9]+)$/\1/' | sort -nu | paste -sd' ' -)"
  row info "listening (tcp)" "${listening:-none}"
  row info "public (tcp)" "${public:-none}"
fi
if is_root && have ufw; then
  ufw_state="$(ufw status 2>/dev/null | awk -F': ' '/^Status:/ {print $2}')"
  if [[ "$ufw_state" == active ]]; then
    rules="$(ufw status 2>/dev/null | awk '/ALLOW|LIMIT/ && !/\(v6\)/ {print $1}' | sort -u | paste -sd' ' -)"
    row ok "firewall (ufw)" "active - allows ${rules:-nothing}"
  else
    row fail "firewall (ufw)" "${ufw_state:-not configured}"
  fi
elif ! have ufw; then
  row warn "firewall (ufw)" "ufw not installed"
fi

# ---------------------------------------------------------------------------
section "Resources"
read -r disk_used disk_size disk_pct < <(df -hP / | awk 'NR==2 {print $3, $2, $5}')
disk_n="${disk_pct%\%}"
if (( disk_n >= DISK_FAIL )); then s=fail; elif (( disk_n >= DISK_WARN )); then s=warn; else s=ok; fi
row "$s" "disk /" "$disk_used of $disk_size used ($disk_pct)"

if have free; then
  read -r mem_total mem_avail < <(free -m | awk '/^Mem:/ {print $2, $7}')
  mem_pct=$(( mem_total > 0 ? (mem_total - mem_avail) * 100 / mem_total : 0 ))
  if (( mem_pct >= 95 )); then s=fail; elif (( mem_pct >= 85 )); then s=warn; else s=ok; fi
  row "$s" "memory" "${mem_pct}% in use - ${mem_avail} MB of ${mem_total} MB available"
  read -r swap_total swap_used < <(free -m | awk '/^Swap:/ {print $2, $3}')
  if (( swap_total == 0 )); then
    row warn "swap" "none configured"
  else
    row ok "swap" "${swap_used} MB used of ${swap_total} MB"
  fi
fi

cores="$(nproc 2>/dev/null || echo 1)"
read -r l1 l5 l15 _ < /proc/loadavg
if awk -v l="$l5" -v c="$cores" 'BEGIN {exit !(l > c * 2)}'; then s=fail
elif awk -v l="$l5" -v c="$cores" 'BEGIN {exit !(l > c)}'; then s=warn
else s=ok; fi
row "$s" "load (1/5/15 min)" "$l1 / $l5 / $l15 on $cores core(s)"

# ---------------------------------------------------------------------------
section "Security"
if is_root && have fail2ban-client; then
  if f2b="$(fail2ban-client status sshd 2>/dev/null)"; then
    now="$(awk -F':[[:space:]]*' '/Currently banned/ {print $2}' <<< "$f2b")"
    total="$(awk -F':[[:space:]]*' '/Total banned/ {print $2}' <<< "$f2b")"
    row ok "fail2ban sshd" "${now:-0} banned now, ${total:-0} since start"
  else
    row fail "fail2ban sshd" "jail not running"
  fi
elif ! have fail2ban-client; then
  row warn "fail2ban" "not installed"
fi

if [[ -r /etc/ssh/sshd_config ]] && have sshd && is_root; then
  pa="$(sshd -T 2>/dev/null | awk '/^passwordauthentication / {print $2}')"
  rl="$(sshd -T 2>/dev/null | awk '/^permitrootlogin / {print $2}')"
  if [[ "$pa" == no && "$rl" == no ]]; then
    row ok "ssh login" "keys only, root login off"
  else
    row warn "ssh login" "password=${pa:-?} root=${rl:-?}"
  fi
fi

if have apt-get; then
  pending="$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst ' || true)"
  security="$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep '^Inst ' | grep -ci security || true)"
  if (( security > 0 )); then s=warn; else s=ok; fi
  row "$s" "updates" "${pending} pending (${security} security)"
fi
if [[ -f /var/run/reboot-required ]]; then
  row warn "reboot" "required ($(paste -sd' ' /var/run/reboot-required.pkgs 2>/dev/null | cut -c1-50))"
else
  row ok "reboot" "not required"
fi

# ---------------------------------------------------------------------------
section "TLS certificates"
if ! is_root; then
  row info "certificates" "run as root to read /etc/letsencrypt"
elif ! compgen -G "/etc/letsencrypt/live/*/cert.pem" >/dev/null; then
  row info "certificates" "none found in /etc/letsencrypt/live"
else
  for cert in /etc/letsencrypt/live/*/cert.pem; do
    name="$(basename "$(dirname "$cert")")"
    end="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)"
    days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
    if (( days < CERT_FAIL_DAYS )); then s=fail; elif (( days < CERT_WARN_DAYS )); then s=warn; else s=ok; fi
    row "$s" "$name" "expires in $days days ($(date -d "$end" +%Y-%m-%d))"
  done
fi

# ---------------------------------------------------------------------------
printf '\n'
if (( FAILS > 0 )); then
  printf '%s%d checks: %d failed, %d warning(s)%s\n' "$C_FAIL" "$CHECKS" "$FAILS" "$WARNS" "$C_OFF"
  exit 1
fi
printf '%s%d checks: all passed, %d warning(s)%s\n' "$C_OK" "$CHECKS" "$WARNS" "$C_OFF"
exit 0
