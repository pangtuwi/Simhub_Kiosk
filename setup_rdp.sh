#!/usr/bin/env bash
# ==============================================================================
# Remote Desktop (RDP) Fallback Setup — GNOME Remote Desktop
# ==============================================================================
# x11vnc fundamentally requires an X11 session. On a Wayland-only Ubuntu
# install (no /usr/share/xsessions/ entry, no Xorg session package available
# in the repos), x11vnc can never work no matter how custom.conf or
# AccountsService are configured — there is nothing for it to attach to.
#
# GNOME's built-in Remote Desktop support works natively over Wayland via
# PipeWire screen capture and needs no Xorg session at all. This script
# configures it in PER-SESSION mode - the same mechanism as GNOME Settings
# > Sharing > Remote Desktop - which mirrors the kiosk's actual running
# autologin'd session, and is reachable with a standard RDP client (Windows'
# built-in "Remote Desktop Connection" / mstsc, or Microsoft Remote Desktop
# on macOS) instead of a VNC client.
#
# Deliberately NOT "system"/headless mode (`grdctl --system`): that spins up
# a brand-new, separate session per RDP login rather than mirroring the one
# already on screen, and - confirmed on real hardware - refuses to do so
# when the target user already has an active session (the autologin'd kiosk
# session itself), failing at login with "there is already a local session
# running". Per-session mode shares the actual live session instead, which
# is what a kiosk needs.
#
# Requires the kiosk user to already be logged in (true for an autologin'd
# kiosk) - it configures RDP against that live session's own D-Bus bus.
#
# Safe to run multiple times. Does not remove or disable x11vnc — the two
# can coexist; use whichever one actually works on your system.
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  Remote Desktop (RDP) Fallback Setup                 ${NC}"
echo -e "${BLUE}======================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Please run with sudo: sudo ./setup_rdp.sh${NC}"
  exit 1
fi

# --- Argument parsing -------------------------------------------------------
TARGET_USER_OVERRIDE=""
RDP_USER_OVERRIDE=""
RDP_PASSWORD=""
ASSUME_YES=0

usage() {
  cat <<USAGE
Usage: sudo ./setup_rdp.sh [--user USERNAME] [--rdp-user NAME] [--rdp-password PASS] [-y|--yes]

  --user USERNAME       The kiosk's login user (for detection only, same
                         convention as step2.sh). Defaults to \$SUDO_USER.
  --rdp-user NAME        Username RDP clients will log in with. Defaults to
                         the kiosk login user.
  --rdp-password PASS    Password RDP clients will use. Prompted for
                         interactively if omitted.
  -y, --yes              Skip the confirmation prompt.
  -h, --help              Show this help and exit.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER_OVERRIDE="$2"; shift 2 ;;
    --user=*) TARGET_USER_OVERRIDE="${1#*=}"; shift ;;
    --rdp-user) RDP_USER_OVERRIDE="$2"; shift 2 ;;
    --rdp-user=*) RDP_USER_OVERRIDE="${1#*=}"; shift ;;
    --rdp-password) RDP_PASSWORD="$2"; shift 2 ;;
    --rdp-password=*) RDP_PASSWORD="${1#*=}"; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo -e "${RED}[ERROR] Unknown argument: $1${NC}"; usage; exit 1 ;;
  esac
done

if [ -n "$TARGET_USER_OVERRIDE" ]; then
  TARGET_USER="$TARGET_USER_OVERRIDE"
elif [ -n "$SUDO_USER" ]; then
  TARGET_USER="$SUDO_USER"
else
  TARGET_USER="$USER"
  echo -e "${YELLOW}[WARNING] \$SUDO_USER is not set — falling back to '${TARGET_USER}'.${NC}"
  echo -e "${YELLOW}          If this isn't your kiosk's login user, re-run with --user <name>.${NC}"
fi

RDP_USER="${RDP_USER_OVERRIDE:-$TARGET_USER}"

if [ -z "$RDP_PASSWORD" ]; then
  echo -e "${YELLOW}Enter the password RDP clients will use to log in as '${RDP_USER}':${NC}"
  read -r -s -p "Password: " RDP_PASSWORD
  echo ""
  if [ -z "$RDP_PASSWORD" ]; then
    echo -e "${RED}[ERROR] A password is required.${NC}"
    exit 1
  fi
fi

echo -e "${BLUE}------------------------------------------------------${NC}"
echo -e "${BLUE}  Kiosk login user : ${TARGET_USER}${NC}"
echo -e "${BLUE}  RDP login user   : ${RDP_USER}${NC}"
echo -e "${BLUE}------------------------------------------------------${NC}"

if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Proceed with these values? [Y/n] " CONFIRM
  case "$CONFIRM" in
    [nN]*) echo -e "${RED}Aborted.${NC}"; exit 1 ;;
  esac
fi

# 1. Install gnome-remote-desktop -------------------------------------------
echo -e "${BLUE}[1/5] Installing gnome-remote-desktop...${NC}"
apt-get update -qq || true
if ! apt-get install -y gnome-remote-desktop; then
  echo -e "${RED}[ERROR] Could not install gnome-remote-desktop. This desktop environment${NC}"
  echo -e "${RED}        may not ship GNOME's Remote Desktop support. Check with:${NC}"
  echo -e "${RED}          apt-cache search remote-desktop${NC}"
  exit 1
fi

if ! command -v grdctl &> /dev/null; then
  echo -e "${RED}[ERROR] grdctl not found after installing gnome-remote-desktop.${NC}"
  exit 1
fi

# 2. Disable system/headless mode if a previous run enabled it --------------
# It actively conflicts with per-session mode: it binds port 3389 itself and
# tries to spawn a new session on login, which fails outright when the
# target user already has one - exactly the "already a local session
# running" error. Stop it so per-session mode can bind the port instead.
echo -e "${BLUE}[2/5] Disabling system/headless RDP mode if previously enabled...${NC}"
if systemctl is-enabled gnome-remote-desktop.service &> /dev/null || systemctl is-active gnome-remote-desktop.service &> /dev/null; then
  systemctl disable --now gnome-remote-desktop.service 2>/dev/null || true
  echo -e "${GREEN}  [OK] Stopped and disabled the system/headless gnome-remote-desktop.service.${NC}"
else
  echo -e "${GREEN}  [OK] System/headless mode was not enabled.${NC}"
fi
command -v grdctl &> /dev/null && grdctl --system rdp disable 2>/dev/null || true

# 3. Confirm the kiosk user actually has a live session ----------------------
echo -e "${BLUE}[3/5] Checking for ${TARGET_USER}'s active session...${NC}"
USER_UID=$(id -u "$TARGET_USER")
USER_BUS_PATH="/run/user/${USER_UID}/bus"
if [ ! -S "$USER_BUS_PATH" ]; then
  echo -e "${RED}[ERROR] No active session bus found for ${TARGET_USER} at ${USER_BUS_PATH}.${NC}"
  echo -e "${RED}        Per-session RDP mode configures the user's already-running graphical${NC}"
  echo -e "${RED}        session, so ${TARGET_USER} needs to actually be logged in first (true${NC}"
  echo -e "${RED}        for an autologin'd kiosk once it's booted). Log in, then re-run this script.${NC}"
  exit 1
fi
USER_BUS="unix:path=${USER_BUS_PATH}"
as_target_user() {
  # timeout: grdctl talks to gnome-shell/mutter over D-Bus, which can hang
  # indefinitely rather than error out if the secret-service ends up wanting
  # to show an unlock/create-keyring prompt with no UI surface to show it on
  # in this non-interactive context - confirmed on real hardware, right
  # after the keyring-rename repair below disrupted a live daemon. Better to
  # fail loudly after 20s than hang the whole script forever.
  timeout 20 sudo -u "$TARGET_USER" env XDG_RUNTIME_DIR="/run/user/${USER_UID}" DBUS_SESSION_BUS_ADDRESS="$USER_BUS" "$@"
}
echo -e "${GREEN}  [OK] Found an active session bus for ${TARGET_USER}.${NC}"
TARGET_USER_HOME=$(eval echo "~${TARGET_USER}")

# 3b. Repair a misnamed default keyring, if one exists -----------------------
# GDM's PAM auto-unlock (pam_gnome_keyring.so, already correctly present in
# /etc/pam.d/gdm-autologin's auth and session stacks on this system - that
# was checked and ruled out as the cause) only ever looks for a keyring
# literally named "login" (~/.local/share/keyrings/login.keyring). Confirmed
# on real hardware: after this kiosk's keyring was wiped and recreated, the
# first thing to touch it was grdctl storing RDP credentials rather than an
# interactive login - which made libsecret auto-create its own generically
# named default collection ("Default_keyring") instead of a "login"-named
# one. PAM then has nothing to even attempt unlocking, which is exactly
# "gkr-pam: no password is available for user" / "couldn't unlock the login
# keyring" - not a failed unlock, a missing target.
echo -e "${BLUE}[*] Checking keyring naming (PAM auto-unlock requires 'login')...${NC}"
KEYRINGS_DIR="${TARGET_USER_HOME}/.local/share/keyrings"
DEFAULT_POINTER="${KEYRINGS_DIR}/default"
if [ -f "$DEFAULT_POINTER" ] && [ ! -f "${KEYRINGS_DIR}/login.keyring" ]; then
  DEFAULT_NAME=$(cat "$DEFAULT_POINTER" 2>/dev/null)
  if [ -n "$DEFAULT_NAME" ] && [ "$DEFAULT_NAME" != "login" ] && [ -f "${KEYRINGS_DIR}/${DEFAULT_NAME}.keyring" ]; then
    echo -e "${YELLOW}[WARNING] Default keyring is named '${DEFAULT_NAME}', not 'login' - PAM${NC}"
    echo -e "${YELLOW}          auto-unlock can never find it. Renaming to login.keyring...${NC}"
    mv "${KEYRINGS_DIR}/${DEFAULT_NAME}.keyring" "${KEYRINGS_DIR}/login.keyring"
    echo "login" > "$DEFAULT_POINTER"
    chown "${TARGET_USER}:${TARGET_USER}" "${KEYRINGS_DIR}/login.keyring" "$DEFAULT_POINTER"
    echo -e "${GREEN}  [OK] Renamed on disk.${NC}"
    echo -e "${YELLOW}[*] Stopping here rather than continuing to configure RDP in this same run.${NC}"
    echo -e "${YELLOW}    The gnome-keyring-daemon already running for this live session still has${NC}"
    echo -e "${YELLOW}    the old file open and doesn't know about the rename - confirmed on real${NC}"
    echo -e "${YELLOW}    hardware that continuing on immediately makes the next grdctl call hang${NC}"
    echo -e "${YELLOW}    indefinitely (it ends up waiting on a keyring prompt with nowhere to be${NC}"
    echo -e "${YELLOW}    shown). Reboot now, then re-run this script - the freshly-booted session${NC}"
    echo -e "${YELLOW}    will find the correctly-named keyring from the start.${NC}"
    echo -e "${YELLOW}      sudo reboot${NC}"
    exit 0
  else
    echo -e "${GREEN}  [OK] Nothing to rename (already 'login', or no default keyring yet).${NC}"
  fi
else
  echo -e "${GREEN}  [OK] Default keyring is already named 'login', or none exists yet.${NC}"
fi

# 4. Generate a self-signed TLS certificate, owned by the kiosk user ---------
echo -e "${BLUE}[4/5] Configuring TLS certificate...${NC}"
CERT_DIR="${TARGET_USER_HOME}/.local/share/gnome-remote-desktop-certs"
CERT_FILE="${CERT_DIR}/rdp-tls.crt"
KEY_FILE="${CERT_DIR}/rdp-tls.key"
mkdir -p "$CERT_DIR"

if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
  openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -subj "/CN=$(hostname)" 2>&1 | tail -5
  echo -e "${GREEN}  [OK] Generated self-signed certificate at ${CERT_FILE}${NC}"
else
  echo -e "${GREEN}  [OK] Certificate already exists at ${CERT_FILE}, leaving it in place.${NC}"
fi

# Per-session mode runs as the logged-in user, not a dedicated system
# account (that was --system mode's own, different, permissions bug -
# fixed separately when that mode was still in use). The cert must be
# owned by TARGET_USER, not root, or the exact same class of failure
# ("TLS certificate and key not yet configured properly") recurs here too.
chown -R "${TARGET_USER}:${TARGET_USER}" "$CERT_DIR"
chmod 700 "$CERT_DIR"
chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

# 5. Configure GNOME Remote Desktop in per-session mode ----------------------
echo -e "${BLUE}[5/5] Configuring RDP via grdctl (per-session)...${NC}"
run_grdctl_step() {
  local desc="$1"; shift
  local rc=0
  set +e
  as_target_user "$@"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
      echo -e "${RED}[ERROR] '${desc}' timed out after 20s instead of completing.${NC}"
      echo -e "${RED}        grdctl is likely stuck waiting on a keyring unlock/create prompt${NC}"
      echo -e "${RED}        that has nowhere to be shown in this non-interactive context.${NC}"
      echo -e "${RED}        This is expected right after the keyring-rename repair above -${NC}"
      echo -e "${RED}        reboot now, then re-run this script; the freshly-booted session${NC}"
      echo -e "${RED}        won't have a live daemon holding the old keyring state open.${NC}"
    else
      echo -e "${RED}[ERROR] '${desc}' failed (exit ${rc}).${NC}"
    fi
    exit 1
  fi
}
run_grdctl_step "set TLS cert" grdctl rdp set-tls-cert "$CERT_FILE"
run_grdctl_step "set TLS key" grdctl rdp set-tls-key "$KEY_FILE"
run_grdctl_step "set credentials" grdctl rdp set-credentials "$RDP_USER" "$RDP_PASSWORD"
run_grdctl_step "enable RDP" grdctl rdp enable
# GNOME Remote Desktop defaults new RDP configs to view-only (screen visible,
# keyboard/mouse input ignored) - confirmed on real hardware: connected fine
# from both Windows and macOS clients, but clicks and typing did nothing
# until this was disabled. A kiosk needs interactive control, not just a
# view, so always turn it off.
run_grdctl_step "disable view-only" grdctl rdp disable-view-only

echo -e "${GREEN}  [OK] Per-session RDP configured for ${TARGET_USER} (interactive, not view-only).${NC}"

# Re-assert this config on every login via autostart, not just once now.
# Confirmed on real hardware: after a reboot, the TLS cert and view-only
# setting survived but the RDP username/password came back empty ("(empty)"
# in `grdctl status`) even though nothing else changed. This kiosk's own
# setup deliberately wipes ~/.local/share/keyrings/* to avoid an autologin
# keyring-unlock password prompt (see KIOSK.md's Keyring Password Prompt
# Removal step) - and GNOME Remote Desktop stores RDP credentials via that
# same keyring/secret-service, so a keyring left unlockable-but-empty for
# autologin's sake means the RDP password specifically doesn't survive past
# the session it was set in. Rather than depend on the keyring working,
# re-supply the full config fresh on every login instead.
echo -e "${BLUE}[*] Installing autostart entry to re-apply RDP config on every login...${NC}"
CRED_FILE="${CERT_DIR}/rdp-credentials.conf"
# %q-quote both values: a password containing shell metacharacters ($, ",
# ', etc. - entirely plausible in a real password) would otherwise corrupt
# or break parsing when this file is later `source`d by the autostart
# script below. Confirmed by testing: an unquoted password with a literal
# '$' and mixed quotes caused a syntax error on source and silently
# dropped/mangled the value.
{
  printf 'RDP_USER=%q\n' "$RDP_USER"
  printf 'RDP_PASSWORD=%q\n' "$RDP_PASSWORD"
} > "$CRED_FILE"
chown "${TARGET_USER}:${TARGET_USER}" "$CRED_FILE"
chmod 600 "$CRED_FILE"

AUTOSTART_SCRIPTS_DIR="${TARGET_USER_HOME}/.config/autostart-scripts"
AUTOSTART_DIR="${TARGET_USER_HOME}/.config/autostart"
mkdir -p "$AUTOSTART_SCRIPTS_DIR" "$AUTOSTART_DIR"

cat > "${AUTOSTART_SCRIPTS_DIR}/rdp-reassert.sh" <<'SCRIPTEOF'
#!/bin/bash
# Re-applies GNOME Remote Desktop's per-session RDP config on every login,
# since credentials specifically do not reliably survive a reboot on a
# kiosk with a deliberately empty/unlockable keyring. Safe to run every
# login - grdctl calls are idempotent.

sleep 5

CERT_DIR="$HOME/.local/share/gnome-remote-desktop-certs"
CRED_FILE="${CERT_DIR}/rdp-credentials.conf"

if [ -f "$CRED_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  grdctl rdp set-tls-cert "${CERT_DIR}/rdp-tls.crt"
  grdctl rdp set-tls-key "${CERT_DIR}/rdp-tls.key"
  grdctl rdp set-credentials "$RDP_USER" "$RDP_PASSWORD"
  grdctl rdp enable
  grdctl rdp disable-view-only
fi
SCRIPTEOF
chmod +x "${AUTOSTART_SCRIPTS_DIR}/rdp-reassert.sh"
chown "${TARGET_USER}:${TARGET_USER}" "${AUTOSTART_SCRIPTS_DIR}/rdp-reassert.sh"

cat > "${AUTOSTART_DIR}/rdp-reassert.desktop" <<DESKTOPEOF
[Desktop Entry]
Type=Application
Exec=${AUTOSTART_SCRIPTS_DIR}/rdp-reassert.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=RDP Config Reassert
Comment=Re-applies GNOME Remote Desktop RDP configuration on login
DESKTOPEOF
chown "${TARGET_USER}:${TARGET_USER}" "${AUTOSTART_DIR}/rdp-reassert.desktop"

echo -e "${GREEN}  [OK] Installed autostart entry - RDP config will be re-applied on every login.${NC}"

echo -e "${BLUE}[*] Verifying RDP is actually listening on port 3389...${NC}"
LISTENING=""
for i in 1 2 3 4 5; do
  if ss -tlnp 2>/dev/null | grep -q ':3389 '; then
    LISTENING=1
    break
  fi
  sleep 1
done
if [ -n "$LISTENING" ]; then
  echo -e "${GREEN}  [OK] Port 3389 is listening.${NC}"
else
  echo -e "${RED}[ERROR] Port 3389 is still not listening.${NC}"
  echo -e "${RED}        RDP will not be reachable. Current status:${NC}"
  as_target_user grdctl status 2>&1 | sed 's/^/    /' || true
fi

RDP_STATUS_OUTPUT=$(as_target_user grdctl status 2>&1 || true)
if echo "$RDP_STATUS_OUTPUT" | grep -q "View-only: yes"; then
  echo -e "${RED}[ERROR] View-only is still enabled — clicks and keyboard input will be${NC}"
  echo -e "${RED}        ignored even though the screen is visible. 'grdctl rdp${NC}"
  echo -e "${RED}        disable-view-only' did not take effect; check the RDP status below.${NC}"
else
  echo -e "${GREEN}  [OK] View-only is disabled — clicks and keyboard input will work.${NC}"
fi

# Open the firewall for RDP if ufw is active ---------------------------------
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
  echo -e "${GREEN}  [OK] ufw is active — allowing 3389/tcp for RDP${NC}"
  ufw allow 3389/tcp
fi

echo -e "${BLUE}[*] RDP status:${NC}"
echo "$RDP_STATUS_OUTPUT" | sed 's/^/    /'

IP_ADDR=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}             RDP SETUP COMPLETE                       ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "Connect from Windows using the built-in ${BLUE}Remote Desktop Connection${NC} app (mstsc):"
echo -e "  Computer: ${BLUE}${IP_ADDR}${NC}"
echo -e "  Username: ${BLUE}${RDP_USER}${NC}"
echo -e "  Password: (the one you just set)"
echo -e ""
echo -e "On macOS, use the ${BLUE}Microsoft Remote Desktop${NC} app from the App Store with the same details."
echo -e ""
echo -e "${YELLOW}Note: this uses a self-signed certificate, so your RDP client will warn${NC}"
echo -e "${YELLOW}about an untrusted certificate on first connect — that's expected on a${NC}"
echo -e "${YELLOW}private LAN kiosk; accept it to continue.${NC}"
echo -e ""
echo -e "This does not require Wayland to be disabled and works alongside (or"
echo -e "instead of) the existing x11vnc setup on port 5900."
