#!/bin/bash
# Storage-agnostic remote backup via rclone. Any rclone remote works
# (Google Drive, OneDrive, Dropbox, S3, SFTP, ...); this file only ever
# calls generic `rclone` subcommands, never anything Drive-specific.
#
# Two destination modes, both driven by OB_CFG_REMOTE_PATH:
#   - OB_CFG_REMOTE_NAME set   -> "<name>:<path>"  (an rclone remote: cloud
#     storage not necessarily mounted locally, e.g. SFTP/S3, or a Drive
#     remote picked from `rclone listremotes`).
#   - OB_CFG_REMOTE_NAME empty -> OB_CFG_REMOTE_PATH is used as a plain
#     absolute local filesystem path instead (rclone treats a bare path as
#     its own "local" backend transparently, no remote needed) -- this is
#     what the bar widget's native folder picker sets: a local directory,
#     which may itself be an rclone-mounted cloud folder (e.g. an existing
#     ~/Projekte Google Drive mount) or a plain disk/NAS path.
#
# Remote layout (identical in both modes):
#   <destination>/<hostname>/index.json            -- lightweight listing of
#       every pushed snapshot's metadata (mirrors state.json), so a fresh
#       install can browse what's available without pulling every payload.
#   <destination>/<hostname>/<snapshot-name>/manifest.json
#   <destination>/<hostname>/<snapshot-name>/checksums.sha256
#   <destination>/<hostname>/<snapshot-name>/payload.tar.zst

ob_remote_configured() {
  ob_require_tool rclone || return 1
  if [ -n "${OB_CFG_REMOTE_NAME:-}" ]; then
    rclone listremotes 2>/dev/null | grep -qxF "${OB_CFG_REMOTE_NAME}:"
  else
    case "${OB_CFG_REMOTE_PATH:-}" in
      /*) return 0 ;;
      *) return 1 ;;
    esac
  fi
}

ob_remote_base() {
  if [ -n "${OB_CFG_REMOTE_NAME:-}" ]; then
    echo "${OB_CFG_REMOTE_NAME}:${OB_CFG_REMOTE_PATH%/}/$(ob_hostname)"
  else
    echo "${OB_CFG_REMOTE_PATH%/}/$(ob_hostname)"
  fi
}

ob_remote_check() {
  # Cheap connectivity/writability probe for `doctor`.
  ob_remote_configured || return 1
  rclone lsd "$(ob_remote_base)" >/dev/null 2>&1 || rclone mkdir "$(ob_remote_base)" >/dev/null 2>&1
}

ob_remote_push() {
  local name="$1"
  ob_remote_configured || ob_die "No remote configured (set OB_CFG_REMOTE_NAME in $OB_CONFIG_FILE)."
  local dir="$OB_SNAPSHOTS_DIR/$name"
  [ -f "$dir/manifest.json" ] || ob_die "No such local snapshot: $name"
  local base; base="$(ob_remote_base)"

  ob_info "Uploading '$name' to $base/$name/ ..."
  rclone copy "$dir" "$base/$name" \
    --include manifest.json --include checksums.sha256 --include payload.tar.zst
  ob_info "Upload complete."

  # Mark as pushed in local state, then refresh the remote index.
  local state; state="$(ob_state_read)"
  state="$(echo "$state" | jq --arg n "$name" '.snapshots |= map(if .name==$n then .remote_pushed=true else . end)')"
  ob_state_write "$state"

  ob_remote_refresh_index
  ob_remote_enforce_retention
}

ob_remote_refresh_index() {
  local base; base="$(ob_remote_base)"
  local index; index="$(ob_state_read | jq '{schema_version:1, snapshots:[.snapshots[] | select(.remote_pushed==true) | {name,created_at,baseline,omarchy_version,size_bytes}]}')"
  local tmp; tmp="$(mktemp)"
  echo "$index" | jq . > "$tmp"
  rclone copyto "$tmp" "$base/index.json"
  rm -f "$tmp"
}

ob_remote_enforce_retention() {
  local keep="${OB_CFG_RETENTION_REMOTE:-3}"
  local base; base="$(ob_remote_base)"
  local index; index="$(rclone cat "$base/index.json" 2>/dev/null || echo '{"snapshots":[]}')"
  local excess
  excess="$(echo "$index" | jq -r --argjson keep "$keep" '.snapshots | sort_by(.created_at) | reverse | .[$keep:] | .[].name')"
  [ -z "$excess" ] && return 0
  local n
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    ob_info "Removing old remote snapshot beyond retention ($keep): $n"
    rclone purge "$base/$n" >/dev/null 2>&1 || true
  done <<< "$excess"
  index="$(echo "$index" | jq --argjson keep "$keep" '.snapshots |= (sort_by(.created_at) | reverse | .[0:$keep])')"
  local tmp; tmp="$(mktemp)"
  echo "$index" | jq . > "$tmp"
  rclone copyto "$tmp" "$base/index.json"
  rm -f "$tmp"
}

ob_remote_list() {
  ob_remote_configured || ob_die "No remote configured."
  local base; base="$(ob_remote_base)"
  rclone cat "$base/index.json" 2>/dev/null \
    | jq -r '["NAME","CREATED","BASELINE","OMARCHY","SIZE"], (.snapshots[] | [.name,.created_at,(.baseline|tostring),.omarchy_version,((.size_bytes/1048576)|floor|tostring)+"MB"]) | @tsv' \
    | column -t -s $'\t'
}

ob_remote_pull() {
  local name="$1" dest="${2:-$OB_SNAPSHOTS_DIR/$name}"
  ob_remote_configured || ob_die "No remote configured."
  local base; base="$(ob_remote_base)"
  mkdir -p "$dest"
  ob_info "Downloading '$name' from $base/$name/ ..."
  rclone copy "$base/$name" "$dest"
  [ -f "$dest/manifest.json" ] || ob_die "Download incomplete or snapshot not found on remote: $name"
  ob_info "Downloaded to $dest"
}
