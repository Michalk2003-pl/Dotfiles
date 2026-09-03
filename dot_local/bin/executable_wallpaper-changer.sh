#!/usr/bin/env bash
# =============================================================================
#  wallpaper-changer.sh — Random wallpaper picker for GNOME 50
#
#  Usage:
#    wallpaper-changer.sh [OPTIONS]
#
#  Options:
#    -d DIR    Directory to pick wallpapers from (default: ~/Pictures/Wallpapers)
#    -m MODE   Picture options: none|wallpaper|centered|scaled|stretched|zoom|spanned
#              (default: zoom)
#    -l FILE   Log file path (default: ~/.local/share/wallpaper-changer.log)
#    -h        Show this help
#
#  Examples:
#    wallpaper-changer.sh
#    wallpaper-changer.sh -d ~/Photos/Landscapes -m zoom
#
#  Supported formats: jpg jpeg png webp bmp tiff gif svg
# =============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
WALLPAPER_DIR="${HOME}/Obrazy/Tapety"
PICTURE_MODE="stretched"
LOG_FILE="${HOME}/.local/share/wallpaper-changer.log"
SUPPORTED_EXT="jpg|jpeg|png|webp|bmp|tiff|gif|svg"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

usage() {
    grep '^#  ' "$0" | sed 's/^#  //'
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while getopts ":d:m:l:h" opt; do
    case $opt in
        d) WALLPAPER_DIR="$OPTARG" ;;
        m) PICTURE_MODE="$OPTARG" ;;
        l) LOG_FILE="$OPTARG" ;;
        h) usage ;;
        :) die "Option -$OPTARG requires an argument." ;;
        \?) die "Unknown option: -$OPTARG" ;;
    esac
done

# ── Validate ──────────────────────────────────────────────────────────────────
[[ -d "$WALLPAPER_DIR" ]] || die "Directory not found: $WALLPAPER_DIR"

valid_modes="none wallpaper centered scaled stretched zoom spanned"
[[ " $valid_modes " == *" $PICTURE_MODE "* ]] \
    || die "Invalid mode '$PICTURE_MODE'. Valid: $valid_modes"

# ── GNOME session check & D-Bus setup ─────────────────────────────────────────
# Systemd user services don't inherit the session environment, so
# DBUS_SESSION_BUS_ADDRESS and XDG_RUNTIME_DIR are never set. Detect them.
_uid=$(id -u)

# XDG_RUNTIME_DIR — always /run/user/<uid> on systemd systems
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${_uid}}"

# Wait up to 30 s for the D-Bus socket to appear (session may still be starting)
_dbus_socket="${XDG_RUNTIME_DIR}/bus"
_waited=0
until [[ -S "$_dbus_socket" ]]; do
    if (( _waited >= 30 )); then
        die "D-Bus socket never appeared at $_dbus_socket after 30 s"
    fi
    log "Waiting for D-Bus socket... (${_waited}s)"
    sleep 2
    (( _waited += 2 ))
done

export DBUS_SESSION_BUS_ADDRESS="unix:path=${_dbus_socket}"
log "D-Bus ready: $DBUS_SESSION_BUS_ADDRESS"

# Make sure gsettings is available
command -v gsettings &>/dev/null || die "'gsettings' not found. Is GNOME installed?"

# ── Pick a random wallpaper ───────────────────────────────────────────────────
# Build array of supported image files (case-insensitive, recursive)
mapfile -d '' IMAGES < <(
    find "$WALLPAPER_DIR" -type f \
        -regextype posix-extended \
        -iregex ".*\.(${SUPPORTED_EXT})" \
        -print0 2>/dev/null | sort -z
)

[[ ${#IMAGES[@]} -gt 0 ]] \
    || die "No supported images found in: $WALLPAPER_DIR"

# Use /dev/urandom for true randomness — $RANDOM is PID-seeded and picks
# the same index on every login because systemd services start with stable PIDs.
COUNT=${#IMAGES[@]}
RAND_INDEX=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
RAND_INDEX=$(( RAND_INDEX % COUNT ))

# Avoid repeating the last wallpaper (stored in a state file)
STATE_FILE="${HOME}/.local/share/wallpaper-changer.last"
LAST=""
[[ -f "$STATE_FILE" ]] && LAST=$(cat "$STATE_FILE")

if [[ $COUNT -gt 1 && "${IMAGES[$RAND_INDEX]}" == "$LAST" ]]; then
    RAND_INDEX=$(( (RAND_INDEX + 1) % COUNT ))
fi

CHOSEN="${IMAGES[$RAND_INDEX]}"
echo "$CHOSEN" > "$STATE_FILE"

CHOSEN_URI="file://$(realpath "$CHOSEN")"

log "Found $COUNT image(s) in '$WALLPAPER_DIR'"
log "Selected: $CHOSEN"

# ── Apply with gsettings ───────────────────────────────────────────────────────
SCHEMA="org.gnome.desktop.background"

gsettings set "$SCHEMA" picture-uri        "$CHOSEN_URI"
gsettings set "$SCHEMA" picture-uri-dark   "$CHOSEN_URI"   # dark-mode too
gsettings set "$SCHEMA" picture-options    "$PICTURE_MODE"

log "Wallpaper applied (mode: $PICTURE_MODE) ✓"
