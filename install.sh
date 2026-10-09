#!/usr/bin/env bash
# install.sh — install one status banner on this server.
#
#   sudo ./install.sh <banner> [--motd] [--yes]
#   sudo ./install.sh <banner> --uninstall
#
# Banners:
#   connector     WBA OpenRoaming Connector    -> /usr/local/bin/openroaming-fetch-connector
#   portal        WBA OpenRoaming Portal       -> /usr/local/bin/openroaming-fetch-portal
#
# Options:
#   --motd        also show the banner on every SSH and console login
#   --yes         never prompt; use whatever can be detected
#   --uninstall   remove the command and its login banner (the config file is kept)
#
# Re-running is safe: it replaces the command with the copy in this checkout and keeps
# any existing config file, so `git pull && sudo ./install.sh portal` is an upgrade.


set -euo pipefail

BIN_DIR=/usr/local/bin
MOTD_DIR=/etc/update-motd.d
CONF_DIR=/etc/default
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The header comment above, up to the first blank line.
usage() { awk 'NR > 1 && /^$/ {exit} NR > 1' "$0" | sed 's/^# \{0,1\}//; s/  *# [a-z]*-only$//'; exit "${1:-0}"; }
say()  { printf '\033[38;2;125;185;40m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[38;2;220;160;40m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[38;2;210;60;60mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# ---- arguments --------------------------------------------------------------
TARGET=""; MOTD=0; YES=0; UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --motd)        MOTD=1 ;;
    --yes|-y)      YES=1 ;;
    --uninstall)   UNINSTALL=1 ;;
    -h|--help)     usage 0 ;;
    -*)            die "unknown option: $arg" ;;
    *)             [ -n "$TARGET" ] && die "one banner at a time"; TARGET="$arg" ;;
  esac
done
[ -z "$TARGET" ] && usage 1

case "$TARGET" in
  connector)   SRC="connector/openroaming-fetch-connector"; NAME="openroaming-fetch-connector" ;;
  portal)      SRC="portal/openroaming-fetch-portal";       NAME="openroaming-fetch-portal" ;;
  *)           die "unknown banner '$TARGET' — expected connector or portal" ;;
esac

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"

BIN="$BIN_DIR/$NAME"
MOTD_FILE="$MOTD_DIR/99-$NAME"
CONF="$CONF_DIR/$NAME"

# ---- uninstall --------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
  for f in "$BIN" "$MOTD_FILE"; do
    [ -e "$f" ] && { rm -f "$f"; say "removed $f"; }
  done
  [ -e "$CONF" ] && say "kept $CONF — delete it yourself if you are done with it"
  exit 0
fi

# ---- prerequisites ----------------------------------------------------------
# The banners degrade to n/a without these rather than failing, so this only warns —
# but a missing tool is the usual reason a field is blank, so say which.
case "$TARGET" in
  connector)   NEEDS="docker openssl ss nsenter" ;;
  portal)      NEEDS="docker openssl curl timeout" ;;
esac
for cmd in $NEEDS; do
  command -v "$cmd" >/dev/null 2>&1 || warn "'$cmd' not found — related fields will show n/a"
done

# ---- right server? ----------------------------------------------------------
# The connector and portal banners are easy to mix up when hopping between servers. Each
# has a container that only exists on its own kind of server, so check before installing.
case "$TARGET" in
  connector) EXPECT="radsecproxy" ;;
  portal)    EXPECT="web" ;;
  *)         EXPECT="" ;;
esac
if [ -n "$EXPECT" ] && command -v docker >/dev/null 2>&1 && \
   [ -z "$(docker ps -aq --filter "label=com.docker.compose.service=$EXPECT" 2>/dev/null)" ]; then
  warn "no '$EXPECT' container here — this doesn't look like an OpenRoaming $TARGET server"
  reply=""
  if [ "$YES" -eq 0 ] && [ -t 0 ]; then
    read -r -p "    install the $TARGET banner anyway? [y/N]: " reply
  fi
  case "$reply" in
    y|Y|yes|YES) ;;
    *) die "stopped — nothing installed. Did you mean: $0 $([ "$TARGET" = connector ] && echo portal || echo connector)" ;;
  esac
fi

# ---- install the command ----------------------------------------------------
[ -r "$REPO/$SRC" ] || die "$REPO/$SRC is missing — run this from a full checkout"
install -m 755 "$REPO/$SRC" "$BIN"
say "installed $BIN"

# ---- site settings ----------------------------------------------------------
# Only the OpenRoaming banners read a config file, and they detect almost everything at
# run time, so this only asks about what detection can't find. An existing config file
# is never touched, so re-running to upgrade keeps your settings.
ask() {  # ask VAR "question" default
  local reply=""
  if [ "$YES" -eq 0 ] && [ -t 0 ]; then
    read -r -p "    $2 [$3]: " reply
  fi
  printf -v "$1" '%s' "${reply:-$3}"
}

# "project|working_dir" of the first container running Compose service $1 whose image
# matches $2 (or any image, if none matches).
compose_home() {
  local all
  all="$(docker ps -a --filter "label=com.docker.compose.service=$1" \
    --format '{{.Image}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}' \
    2>/dev/null || true)"
  { echo "$all" | grep -i "$2" || echo "$all"; } | head -1 | cut -d'|' -f2-
}

write_conf() {
  umask 022
  cat > "$CONF"
  say "wrote $CONF"
}

# Organisation name and support contact — the two things only a person can answer.
# Sets ORG_LINE and SUPPORT_LINE for the config file. $1 is what the banner would show
# on its own (may be empty), $2 says where that comes from.
ask_identity() {
  ask ORG_IN "organisation name shown under the title ($2)" "$1"
  if [ -n "$ORG_IN" ] && [ "$ORG_IN" != "$1" ]; then
    ORG_LINE="ORG=\"$ORG_IN\""
  else
    ORG_LINE="#ORG=\"${1:-Example Wireless}\""
  fi
  ask SUPPORT_IN "support contact shown at the bottom" "jonah@wballiance.com"
  if [ "$SUPPORT_IN" != "jonah@wballiance.com" ]; then
    SUPPORT_LINE="SUPPORT=\"$SUPPORT_IN\""
  else
    SUPPORT_LINE='#SUPPORT="jonah@wballiance.com"'
  fi
}

if [ "$TARGET" = connector ] || [ "$TARGET" = portal ]; then
  if [ -e "$CONF" ]; then
    say "keeping existing $CONF"
  elif [ "$TARGET" = connector ]; then
    FOUND="$(compose_home radsecproxy .)"
    if [ -n "$FOUND" ]; then
      say "found the connector at ${FOUND#*|} (Compose project ${FOUND%%|*})"
      DIR_LINE='#CONNECTOR_DIR="/root/wba-openroaming-connector"'
    else
      warn "couldn't find a running connector to read its location from"
      ask CONNECTOR_DIR "connector checkout (the folder containing hybrid/)" "/root/wba-openroaming-connector"
      # Keep the default commented out so detection takes over once the containers run.
      if [ "$CONNECTOR_DIR" = "/root/wba-openroaming-connector" ]; then
        DIR_LINE='#CONNECTOR_DIR="/root/wba-openroaming-connector"'
      else
        DIR_LINE="CONNECTOR_DIR=\"$CONNECTOR_DIR\""
      fi
    fi
    # The WBA issues your client certificate in your organisation's name.
    HYB="${FOUND#*|}"; [ -n "$FOUND" ] || HYB="$CONNECTOR_DIR/hybrid"
    CERT_ORG="$(openssl x509 -noout -subject -in "$HYB/configs/radsecproxy/certs/client.pem" 2>/dev/null \
      | sed -n 's/.*[,=/ ]O *= *\([^,/]*\).*/\1/p' || true)"
    ask_identity "$CERT_ORG" "blank = none; default is from your WBA certificate"
    write_conf <<EOF
# Settings for $NAME. Read every time it runs, including from MOTD.
# Everything commented out is detected at run time; uncomment to override.

# The wba-openroaming-connector checkout, its hybrid/ folder, and the Compose project.
# Normally read off the running radsecproxy container.
$DIR_LINE
#HYBRID_DIR="/root/wba-openroaming-connector/hybrid"
#COMPOSE_PROJECT="hybrid"

# How far back to count Access-Accept / Access-Reject in the FreeRADIUS log.
#AUTH_WINDOW="1h"

#REPO_URL="github.com/wireless-broadband-alliance/wba-openroaming-connector"

# Header line, the organisation shown under it (defaults to the O= field of your WBA
# certificate), and the support contact.
#TITLE="WBA OpenRoaming Connector"
$ORG_LINE
$SUPPORT_LINE
EOF
  else
    FOUND="$(compose_home web openroaming)"
    if [ -n "$FOUND" ]; then
      say "found the portal at ${FOUND#*|} (Compose project ${FOUND%%|*})"
      DIR_LINE='#PORTAL_DIR="/root/wba-openroaming-portal"'
    else
      warn "couldn't find a running portal to read its location from"
      ask PORTAL_DIR "portal checkout" "/root/wba-openroaming-portal"
      # Keep the default commented out so detection takes over once the containers run.
      if [ "$PORTAL_DIR" = "/root/wba-openroaming-portal" ]; then
        DIR_LINE='#PORTAL_DIR="/root/wba-openroaming-portal"'
      else
        DIR_LINE="PORTAL_DIR=\"$PORTAL_DIR\""
      fi
    fi
    # Same order the banner uses: the web container's redirect, then DEFAULT_URI, then
    # the SAML address. Only ask when none of them names a public host.
    url_base() { sed -n -E 's#^(https?://[^/:]+).*#\1#p' | grep -v -e 127.0.0.1 -e localhost -e example.com || true; }
    WEB_ID="$(docker ps -q --filter label=com.docker.compose.service=web 2>/dev/null | head -1 || true)"
    # Each lookup is allowed to fail (no portal answering, variable unset): under set -e
    # and pipefail a failed curl would otherwise end the install right here.
    DETECTED="$(curl -s -o /dev/null --max-time 5 -w '%{redirect_url}' http://127.0.0.1/ 2>/dev/null | url_base || true)"
    if [ -z "$DETECTED" ] && [ -n "$WEB_ID" ]; then
      DETECTED="$(docker exec "$WEB_ID" printenv DEFAULT_URI 2>/dev/null | url_base || true)"
    fi
    if [ -z "$DETECTED" ] && [ -n "$WEB_ID" ]; then
      DETECTED="$(docker exec "$WEB_ID" printenv SAML_SP_ACS_URL 2>/dev/null | url_base || true)"
    fi
    if [ -n "$DETECTED" ]; then
      say "found the public portal URL: $DETECTED"
      URL_LINE="#PORTAL_URL=\"$DETECTED\""
    else
      warn "couldn't detect the portal's public URL"
      ask PORTAL_URL "public portal URL, e.g. https://portal.example.com" ""
      if [ -n "$PORTAL_URL" ]; then
        URL_LINE="PORTAL_URL=\"$PORTAL_URL\""
      else
        URL_LINE='#PORTAL_URL="https://portal.example.com"'
      fi
    fi
    ask_identity "" "blank = use the portal's Display Name setting"
    write_conf <<EOF
# Settings for $NAME. Read every time it runs, including from MOTD.
# Everything commented out is detected at run time; uncomment to override.

# The wba-openroaming-portal checkout and its Compose project. Normally read off the
# running web container.
$DIR_LINE
#COMPOSE_PROJECT="wba-openroaming-portal"

# The address users enrol at, checked from outside including its TLS certificate.
# Normally detected from the portal's own redirect to its public https:// address.
$URL_LINE

# The web container as published on this host.
#LOCAL_URL="http://127.0.0.1"

#REPO_URL="github.com/wireless-broadband-alliance/wba-openroaming-portal"

# Header line, the organisation shown under it (defaults to the portal's Display Name
# setting), and the support contact.
#TITLE="WBA OpenRoaming Portal"
$ORG_LINE
$SUPPORT_LINE
EOF
  fi
fi

# ---- login banner -----------------------------------------------------------
# MOTD scripts run as root via pam_motd, so the login banner gets the full picture.
# Without --motd, offer it — unless it's already on (an upgrade keeps it) or nobody is
# at the keyboard to answer.
if [ -e "$MOTD_FILE" ]; then
  MOTD=1
elif [ "$MOTD" -eq 0 ] && [ "$YES" -eq 0 ] && [ -t 0 ] && [ -d "$MOTD_DIR" ]; then
  read -r -p "    show this banner every time someone logs in? [Y/n]: " reply
  case "$reply" in n|N|no|NO) ;; *) MOTD=1 ;; esac
fi
if [ "$MOTD" -eq 1 ]; then
  if [ -d "$MOTD_DIR" ]; then
    printf '#!/bin/sh\n%s\n' "$BIN" > "$MOTD_FILE"
    chmod 755 "$MOTD_FILE"
    say "login banner enabled: $MOTD_FILE"
  else
    warn "$MOTD_DIR not found — this system does not use update-motd, skipping login banner"
  fi
fi

# ---- try it -----------------------------------------------------------------
say "running $NAME:"
"$BIN" || warn "$NAME exited non-zero — the banner above shows what it could read"

echo
say "done. Run it any time with: sudo $NAME"
[ "$MOTD" -eq 0 ] && say "add it to the login banner with: sudo $0 $TARGET --motd"
[ -e "$CONF" ] && say "change site settings in: $CONF"
exit 0
