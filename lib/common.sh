#!/bin/bash
# Shared helpers for omarchy-backup. Sourced by bin/omarchy-backup and lib/*.sh.
# Expects: set -uo pipefail already active in the caller (intentionally no -e;
# see the comment in bin/omarchy-backup).

OB_VERSION="0.1.1"

OB_CONFIG_DIR="${OMARCHY_BACKUP_CONFIG_DIR:-$HOME/.config/omarchy-backup}"
OB_DATA_DIR="${OMARCHY_BACKUP_DATA_DIR:-$HOME/.local/share/omarchy-backup}"
OB_SNAPSHOTS_DIR="$OB_DATA_DIR/snapshots"
OB_STATE_FILE="$OB_DATA_DIR/state.json"
OB_LOG_DIR="$OB_DATA_DIR/logs"
OB_CONFIG_FILE="$OB_CONFIG_DIR/config.conf"
OB_PATHS_FILE="$OB_CONFIG_DIR/paths.conf"
OB_PATHS_D_DIR="$OB_CONFIG_DIR/paths.d"
OB_MAX_SNAPSHOTS=3

ob_lib_dir() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
}
OB_LIB_DIR="$(ob_lib_dir)"
OB_ROOT_DIR="$(cd -- "$OB_LIB_DIR/.." && pwd)"

# --- logging -----------------------------------------------------------

ob_ts() { date '+%Y-%m-%d %H:%M:%S'; }

ob_log()  { printf '[%s] %s\n' "$(ob_ts)" "$*" >&2; }
ob_info() { ob_log "INFO  $*"; }
ob_warn() { ob_log "WARN  $*"; }
ob_err()  { ob_log "ERROR $*"; }
ob_die()  { ob_err "$*"; exit 1; }

ob_log_to_file() {
  # ob_log_to_file <logfile-basename> -- appends stdin/stderr of the rest of
  # the invoking command to a log file as well as the terminal, for auto runs.
  local base="$1"
  mkdir -p "$OB_LOG_DIR"
  echo "$OB_LOG_DIR/$base-$(date '+%Y%m%d-%H%M%S').log"
}

# --- setup / dirs --------------------------------------------------------

ob_ensure_dirs() {
  mkdir -p "$OB_CONFIG_DIR" "$OB_PATHS_D_DIR" "$OB_DATA_DIR" "$OB_SNAPSHOTS_DIR" "$OB_LOG_DIR" || return 1
  ob_write_default_config || return 1
  ob_write_default_paths || return 1
}

# --- config loading --------------------------------------------------------

# Defaults; overridden by config.conf (simple KEY=VALUE, bash-sourceable).
OB_CFG_ENABLED="true"
OB_CFG_SNAPSHOT_FREQUENCY="daily"      # systemd OnCalendar expression or daily/weekly/monthly
OB_CFG_DOCTOR_FREQUENCY="monthly"
OB_CFG_REMOTE_NAME=""                   # rclone remote name, e.g. "gdrive"
OB_CFG_REMOTE_PATH="omarchy-backup"     # path within the remote
OB_CFG_RETENTION_REMOTE=3
OB_CFG_MAX_FILE_SIZE_MB=20
OB_CFG_SKIP_AUTO_IF_CLEAN="true"

ob_load_config() {
  if [ -f "$OB_CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$OB_CONFIG_FILE"
  fi
}

ob_write_default_config() {
  [ -f "$OB_CONFIG_FILE" ] && return 0
  cat > "$OB_CONFIG_FILE" <<'EOF'
# omarchy-backup configuration
# Simple KEY=VALUE, sourced by bash. See README.md for details.

# Master switch for automatic (timer-driven) snapshot + doctor runs.
OB_CFG_ENABLED=true

# How often automatic snapshots run. One of: daily, weekly, monthly,
# or any systemd OnCalendar expression (applied via `omarchy-backup timers install`).
OB_CFG_SNAPSHOT_FREQUENCY=daily

# How often the automatic doctor check runs.
OB_CFG_DOCTOR_FREQUENCY=monthly

# rclone remote name (see `rclone listremotes`), for a destination that
# isn't mounted as a local folder (S3, SFTP, an unmounted Drive remote, ...).
# Leave empty to use OB_CFG_REMOTE_PATH as a plain local folder instead
# (e.g. an existing rclone-mounted Google Drive folder, a NAS mount, or any
# other local/mounted path) -- the bar widget's folder picker sets it this
# way. <hostname>/ is created under whichever destination this resolves to.
OB_CFG_REMOTE_NAME=

# With OB_CFG_REMOTE_NAME set: the path inside that remote.
# With OB_CFG_REMOTE_NAME empty: an absolute local folder path.
OB_CFG_REMOTE_PATH=omarchy-backup

# Total snapshot archives to keep on the remote (per hostname). The known-good
# baseline is always protected; the remaining slots hold the newest rolling
# snapshots. With the default 3 this means one baseline plus two rolling copies.
OB_CFG_RETENTION_REMOTE=3

# Files larger than this (inside included config paths) are skipped and
# reported as a manual step instead of being embedded in the snapshot.
OB_CFG_MAX_FILE_SIZE_MB=20

# If true, automatic (timer-driven) snapshots are skipped when `status`
# reports GREEN (no drift since the baseline).
OB_CFG_SKIP_AUTO_IF_CLEAN=true
EOF
  ob_info "Wrote default config: $OB_CONFIG_FILE"
}

ob_write_default_paths() {
  [ -f "$OB_PATHS_FILE" ] && return 0
  cp "$OB_ROOT_DIR/config/paths.conf.default" "$OB_PATHS_FILE"
  ob_info "Wrote default paths manifest: $OB_PATHS_FILE"
}

# --- paths.conf parsing --------------------------------------------------
# Format (one entry per line, '#' comments and blank lines ignored):
#   include <path>        path may use ~ for $HOME
#   exclude <glob>        glob matched against the full expanded path
# Read paths.conf plus every *.conf file in paths.d/, in that order.

ob_paths_files() {
  [ -f "$OB_PATHS_FILE" ] && echo "$OB_PATHS_FILE"
  if [ -d "$OB_PATHS_D_DIR" ]; then
    find "$OB_PATHS_D_DIR" -maxdepth 1 -name '*.conf' -type f | sort
  fi
  return 0
}

ob_expand_path() {
  local p="$1"
  case "$p" in
    "~"|"~/"*) p="$HOME${p#\~}" ;;
  esac
  printf '%s' "$p"
}

# Populates two global arrays: OB_INCLUDES and OB_EXCLUDES
ob_read_path_rules() {
  OB_INCLUDES=()
  OB_EXCLUDES=()
  local f line kind val
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [ -z "$line" ] && continue
      kind="${line%% *}"
      val="${line#* }"
      [ "$kind" = "$line" ] && continue
      val="$(ob_expand_path "$val")"
      case "$kind" in
        include) OB_INCLUDES+=("$val") ;;
        exclude) OB_EXCLUDES+=("$val") ;;
      esac
    done < "$f"
  done < <(ob_paths_files)
}

# Always-on safety net: never embed these, regardless of what paths.conf says.
OB_SECRET_GLOBS=(
  "*.credentials.json" "credentials.json" "auth.json" "oauth_creds*.json"
  "*token*" "*secret*" "*.key" "*.pem" "id_rsa*" "id_ed25519*" "id_ecdsa*"
  ".netrc" "*.p12" "*.pfx" "shadow" "gshadow"
)

ob_matches_any_glob() {
  local path="$1"; shift
  local base
  base="$(basename -- "$path")"
  local g
  for g in "$@"; do
    # shellcheck disable=SC2254
    case "$path" in $g) return 0 ;; esac
    # shellcheck disable=SC2254
    case "$base" in $g) return 0 ;; esac
  done
  return 1
}

# --- misc ------------------------------------------------------------------

ob_require_tool() {
  command -v "$1" >/dev/null 2>&1
}

ob_hostname() { hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown-host"; }

ob_confirm() {
  # ob_confirm "question" -> 0 (yes) / 1 (no). Non-interactive => no.
  local q="$1"
  if [ ! -t 0 ]; then
    return 1
  fi
  local ans
  read -r -p "$q [y/N] " ans || return 1
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

ob_notify() {
  # Best-effort desktop notification; never fails the caller.
  local title="$1" body="$2" urgency="${3:-normal}"
  if ob_require_tool notify-send; then
    notify-send -u "$urgency" -a "omarchy-backup" "$title" "$body" 2>/dev/null || true
  fi
}
