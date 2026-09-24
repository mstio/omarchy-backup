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
  ob_require_tool timeout || return 1
  if [ -n "${OB_CFG_REMOTE_NAME:-}" ]; then
    rclone listremotes 2>/dev/null | grep -qxF "${OB_CFG_REMOTE_NAME}:"
  else
    case "${OB_CFG_REMOTE_PATH:-}" in
      /*) return 0 ;;
      *) return 1 ;;
    esac
  fi
}

# Every write to the destination is gated by ob_remote_ensure_available:
#   1. The configured destination root must already exist (local path) or the
#      rclone remote must answer -- the tool never creates the root itself, so
#      an unmounted drive/mountpoint can't silently receive the backup on the
#      local disk.
#   2. Identity marker: the first push writes a random id to
#      <root>/.omarchy-backup-destination and remembers it in state.json
#      (.destinations[<root>]). Later writes require exactly that marker, which
#      also catches an existing-but-empty mountpoint or a different drive
#      mounted at the same path. A fresh install (empty state) adopts an
#      existing marker, so restores onto new machines keep working.
OB_DESTINATION_MARKER=".omarchy-backup-destination"

ob_remote_root() {
  if [ -n "${OB_CFG_REMOTE_NAME:-}" ]; then
    echo "${OB_CFG_REMOTE_NAME}:${OB_CFG_REMOTE_PATH%/}"
  else
    echo "${OB_CFG_REMOTE_PATH%/}"
  fi
}

ob_remote_read_marker() {
  timeout --signal=TERM --kill-after=5s "${OB_REMOTE_INDEX_TIMEOUT_SECONDS}s" \
    rclone cat "$1/$OB_DESTINATION_MARKER" --count 200 2>/dev/null \
    | head -n 1 | tr -cd 'A-Za-z0-9-'
}

# Usage: ob_remote_ensure_available [--check]
# --check never writes (doctor, pre-flight of automatic runs).
ob_remote_ensure_available() {
  local check_only=false
  [ "${1:-}" = "--check" ] && check_only=true
  ob_remote_configured || { ob_err "No remote backup destination configured."; return 1; }
  local root expected actual id tmp state
  root="$(ob_remote_root)"

  if [ -z "${OB_CFG_REMOTE_NAME:-}" ]; then
    if [ ! -d "$root" ]; then
      ob_err "Backup destination '$root' does not exist (drive/share not mounted?); refusing to write. The destination folder is never created automatically."
      return 1
    fi
    if [ ! -w "$root" ]; then
      ob_err "Backup destination '$root' is not writable; refusing to write."
      return 1
    fi
  elif ! timeout --signal=TERM --kill-after=5s 30s \
      rclone lsf --max-depth 1 "${OB_CFG_REMOTE_NAME}:" >/dev/null 2>&1; then
    ob_err "rclone remote '${OB_CFG_REMOTE_NAME}:' is not reachable (offline or not authenticated?); refusing to write."
    return 1
  fi

  expected="$(ob_state_read | jq -r --arg d "$root" '.destinations[$d] // empty')"
  actual="$(ob_remote_read_marker "$root")"
  if [ -n "$expected" ]; then
    if [ "$actual" != "$expected" ]; then
      ob_err "Backup destination '$root' is missing its identity marker ($OB_DESTINATION_MARKER, expected $expected, found '${actual:-none}') -- probably not mounted, or a different drive is attached; refusing to write."
      return 1
    fi
    return 0
  fi

  # First use of this destination on this machine.
  [ "$check_only" = "true" ] && return 0
  if [ -n "$actual" ]; then
    id="$actual"
  else
    id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)"
    tmp="$(mktemp)" || return 1
    printf '%s\n' "$id" > "$tmp"
    if ! timeout --signal=TERM --kill-after=5s "${OB_REMOTE_INDEX_TIMEOUT_SECONDS}s" \
        rclone copyto "$tmp" "$root/$OB_DESTINATION_MARKER" >/dev/null 2>&1; then
      rm -f -- "$tmp"
      ob_err "Could not write the identity marker to '$root'; refusing to write."
      return 1
    fi
    rm -f -- "$tmp"
    ob_info "Registered backup destination '$root' (identity marker $OB_DESTINATION_MARKER)."
  fi
  state="$(ob_state_read | jq --arg d "$root" --arg id "$id" '.destinations = ((.destinations // {}) + {($d): $id})')" || return 1
  ob_state_write "$state"
}

ob_remote_base() {
  if [ -n "${OB_CFG_REMOTE_NAME:-}" ]; then
    echo "${OB_CFG_REMOTE_NAME}:${OB_CFG_REMOTE_PATH%/}/$(ob_hostname)"
  else
    echo "${OB_CFG_REMOTE_PATH%/}/$(ob_hostname)"
  fi
}

ob_remote_snapshot_target() {
  local base="$1" name="$2" target
  ob_snapshot_name_valid "$name" || return 1
  base="${base%/}"
  [ -n "$base" ] || return 1
  target="$base/$name"
  case "$target" in
    "$base"/*) printf '%s\n' "$target" ;;
    *) return 1 ;;
  esac
}

ob_remote_index_target() {
  local base="${1%/}"
  [ -n "$base" ] || return 1
  printf '%s/index.json\n' "$base"
}

ob_remote_index_valid() {
  local file="$1"
  jq -e \
    --argjson max_entries "$OB_REMOTE_INDEX_MAX_ENTRIES" \
    --argjson max_name "$OB_SNAPSHOT_NAME_MAX" '
      type == "object"
      and .schema_version == 1
      and (.snapshots | type == "array" and length <= $max_entries)
      and ([.snapshots[].name] | length == (unique | length))
      and all(.snapshots[];
        type == "object"
        and (.name | type == "string" and length <= $max_name
             and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
        and (.created_at | type == "string" and length <= 64
             and test("^[0-9T:+.-]+$"))
        and (.baseline | type == "boolean")
        and (.omarchy_version | type == "string" and length <= 128
             and test("^[A-Za-z0-9][A-Za-z0-9._+:-]*$"))
        and (.size_bytes | type == "number" and . >= 0 and . <= 1099511627776)
      )
    ' "$file" >/dev/null 2>&1
}

# Remote input is hostile until proven otherwise. `--count` bounds bytes at
# the producer, while coreutils timeout puts a hard wall-clock limit around
# even a wedged backend. Exit 3 means the index does not exist yet.
#
# Caching/eventually-consistent destinations can briefly serve stale or
# zero-filled content right after the index was replaced (observed with an
# rclone VFS mount: first read after `copyto` returned only NUL bytes). An
# invalid read is therefore retried a few times before it counts as corrupt.
OB_REMOTE_INDEX_READ_ATTEMPTS=5

ob_remote_read_index() {
  local base="$1" target tmp rc size attempt
  target="$(ob_remote_index_target "$base")" || return 1
  tmp="$(mktemp)" || return 1
  for ((attempt = 1; attempt <= OB_REMOTE_INDEX_READ_ATTEMPTS; attempt++)); do
    [ "$attempt" -gt 1 ] && sleep 1
    timeout --signal=TERM --kill-after=5s "${OB_REMOTE_INDEX_TIMEOUT_SECONDS}s" \
      rclone cat "$target" --count "$((OB_REMOTE_INDEX_MAX_BYTES + 1))" \
      > "$tmp" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -f -- "$tmp"
      if [ "$rc" -eq 3 ]; then
        return 3
      fi
      ob_err "Could not read remote snapshot index within the safety deadline."
      return 1
    fi
    size="$(stat -c '%s' -- "$tmp" 2>/dev/null || echo "$((OB_REMOTE_INDEX_MAX_BYTES + 1))")"
    if [ "$size" -gt "$OB_REMOTE_INDEX_MAX_BYTES" ]; then
      rm -f -- "$tmp"
      ob_err "Remote snapshot index exceeds the ${OB_REMOTE_INDEX_MAX_BYTES}-byte safety limit."
      return 1
    fi
    if ob_remote_index_valid "$tmp"; then
      cat -- "$tmp"
      rm -f -- "$tmp"
      return 0
    fi
  done
  rm -f -- "$tmp"
  ob_err "Remote snapshot index has an invalid or unsafe schema."
  return 1
}

ob_remote_check() {
  # Read-only availability probe for `doctor` -- never creates anything.
  ob_remote_ensure_available --check 2>/dev/null
}

ob_remote_push() {
  local name="$1"
  ob_require_snapshot_name "$name"
  ob_remote_configured || ob_die "No remote configured (set OB_CFG_REMOTE_NAME in $OB_CONFIG_FILE)."
  local dir="$OB_SNAPSHOTS_DIR/$name"
  ob_snapshot_verify_for_push "$name" || return 1
  ob_remote_ensure_available || return 1
  local base target
  base="$(ob_remote_base)"
  target="$(ob_remote_snapshot_target "$base" "$name")" \
    || ob_die "Refusing unsafe remote snapshot target for '$name'."

  ob_info "Uploading '$name' to $target/ ..."
  if ! timeout --signal=TERM --kill-after=5s "${OB_REMOTE_OPERATION_TIMEOUT_SECONDS}s" \
      rclone copy "$dir" "$target" \
      --include manifest.json --include checksums.sha256 --include payload.tar.zst; then
    ob_err "Upload of '$name' failed; it was not added to the remote index."
    return 1
  fi
  ob_info "Upload copied; verifying remote files against the local snapshot ..."
  if ! timeout --signal=TERM --kill-after=5s "${OB_REMOTE_OPERATION_TIMEOUT_SECONDS}s" \
      rclone check "$dir" "$target" \
      --include manifest.json --include checksums.sha256 --include payload.tar.zst; then
    ob_err "Remote verification of '$name' failed; it was not added to the remote index."
    return 1
  fi

  # Mark as pushed in local state, then refresh the remote index.
  local state; state="$(ob_state_read)"
  state="$(echo "$state" | jq --arg n "$name" '.snapshots |= map(if .name==$n then .remote_pushed=true else . end)')"
  ob_state_write "$state" || return 1

  ob_remote_refresh_index || return 1
  ob_remote_enforce_retention || return 1
  ob_info "Upload complete and verified."
}

# Uploads what an earlier automatic run could not: the latest local snapshot
# and the current baseline, if either is not on the remote yet. Older
# unpushed rolling snapshots are superseded by the latest one and skipped.
ob_remote_push_pending() {
  local latest baseline n rc=0
  latest="$(ob_latest_snapshot_name)"
  baseline="$(ob_state_baseline_name)"
  for n in $(printf '%s\n%s\n' "$baseline" "$latest" | awk 'NF && !seen[$0]++'); do
    if [ "$(ob_state_read | jq -r --arg n "$n" '.snapshots[] | select(.name==$n) | .remote_pushed // false')" != "true" ]; then
      ob_info "Uploading pending snapshot '$n' from an earlier run."
      ob_remote_push "$n" || rc=1
    fi
  done
  return "$rc"
}

ob_remote_has_pending() {
  local latest baseline
  latest="$(ob_latest_snapshot_name)"
  baseline="$(ob_state_baseline_name)"
  ob_state_read | jq -e --arg l "$latest" --arg b "$baseline" \
    '[.snapshots[] | select((.name==$l or .name==$b) and (.remote_pushed // false) != true)] | length > 0' >/dev/null
}

ob_snapshot_verify_for_push() {
  local name="$1" dir="$OB_SNAPSHOTS_DIR/$1" required
  for required in manifest.json checksums.sha256 payload.tar.zst; do
    if [ ! -f "$dir/$required" ]; then
      ob_err "Local snapshot '$name' is incomplete (missing $required); refusing upload."
      return 1
    fi
  done
  if ! jq -e '.schema_version and .payload.file and .payload.sha256' "$dir/manifest.json" >/dev/null 2>&1; then
    ob_err "Local snapshot '$name' has an invalid manifest; refusing upload."
    return 1
  fi
  local stored actual
  stored="$(jq -r '.payload.sha256' "$dir/manifest.json")"
  actual="$(sha256sum -- "$dir/payload.tar.zst" 2>/dev/null | awk '{print $1}')"
  if [ -z "$stored" ] || [ "$stored" != "$actual" ]; then
    ob_err "Local snapshot '$name' failed its payload checksum; refusing upload."
    return 1
  fi
}

ob_remote_refresh_index() {
  local base; base="$(ob_remote_base)"
  local existing='{"schema_version":1,"snapshots":[]}' remote_raw read_rc
  if remote_raw="$(ob_remote_read_index "$base")"; then
    existing="$remote_raw"
  else
    read_rc=$?
    [ "$read_rc" -eq 3 ] || return 1
  fi
  local current index current_baseline
  current="$(ob_state_read | jq '{schema_version:1, snapshots:[.snapshots[] | select(.remote_pushed==true) | {name,created_at,baseline,omarchy_version,size_bytes}]}')"
  # Only the baseline the user most recently set on purpose (`baseline <name>`
  # or `snapshot --baseline`; automatic runs never set one) is protected on
  # the remote. Earlier baselines -- including ones whose local slot has
  # already rotated away and would otherwise keep baseline=true in the remote
  # index forever -- are demoted and rotate like rolling snapshots. Demotion
  # only happens once the current baseline is actually on the remote, so the
  # remote is never left without a protected baseline.
  current_baseline="$(ob_state_baseline_name)"
  index="$(jq -n --argjson existing "$existing" --argjson current "$current" --arg cb "$current_baseline" '
    ((reduce (($existing.snapshots // []) + ($current.snapshots // []))[] as $snapshot
      ({}; .[$snapshot.name] = $snapshot)) | [.[]] | sort_by(.created_at)) as $merged
    | {
        schema_version: 1,
        snapshots: (if $cb != "" and ($merged | map(.name) | index($cb)) != null
                    then $merged | map(.baseline = (.name == $cb))
                    else
                      # Current baseline not uploaded yet (or none set on this
                      # machine): the remote keeps the protection it already
                      # records; local demotions must not strip it.
                      [($existing.snapshots // [])[] | select(.baseline == true) | .name] as $eb
                      | [($existing.snapshots // [])[] | .name] as $known
                      | $merged | map(.baseline = (
                          (.name as $n | $eb | index($n)) != null
                          or ((.name as $n | $known | index($n)) == null and .baseline == true)))
                    end)
      }
  ')" || return 1
  local tmp target; tmp="$(mktemp)"
  echo "$index" | jq . > "$tmp"
  ob_remote_index_valid "$tmp" || { rm -f -- "$tmp"; ob_err "Refusing to write an unsafe remote snapshot index."; return 1; }
  target="$(ob_remote_index_target "$base")" || { rm -f -- "$tmp"; return 1; }
  if ! timeout --signal=TERM --kill-after=5s "${OB_REMOTE_OPERATION_TIMEOUT_SECONDS}s" \
      rclone copyto "$tmp" "$target"; then
    rm -f "$tmp"
    ob_err "Could not update remote snapshot index."
    return 1
  fi
  rm -f "$tmp"
}

ob_remote_enforce_retention() {
  local keep="${OB_CFG_RETENTION_REMOTE:-3}"
  local base; base="$(ob_remote_base)"
  local index
  index="$(ob_remote_read_index "$base")" || return 1
  local selection excess retained
  selection="$(echo "$index" | jq --argjson keep "$keep" '
    (.snapshots | map(select(.baseline == true)) | sort_by(.created_at) | reverse) as $baselines
    | ([($keep - ($baselines | length)), 0] | max) as $rolling_slots
    | (.snapshots | map(select(.baseline != true)) | sort_by(.created_at) | reverse | .[0:$rolling_slots]) as $rolling
    | ($baselines + $rolling) as $kept
    | {
        kept: $kept,
        excess: [.snapshots[] | select(.name as $name | ($kept | map(.name) | index($name) | not))]
      }
  ')" || return 1
  excess="$(echo "$selection" | jq -r '.excess[].name')"
  retained="$(echo "$selection" | jq '{schema_version:1, snapshots:(.kept | sort_by(.created_at))}')"
  local n
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    local target
    target="$(ob_remote_snapshot_target "$base" "$n")" || {
      ob_err "Refusing unsafe remote snapshot name from index: '$n'"
      return 1
    }
    # A snapshot pruned by an earlier push can reappear in the index via the
    # local state (it still says remote_pushed=true); purging a directory
    # that is already gone must not fail the whole push.
    if ! timeout --signal=TERM --kill-after=5s "${OB_REMOTE_INDEX_TIMEOUT_SECONDS}s" \
        rclone lsf --max-depth 1 "$target" >/dev/null 2>&1; then
      ob_info "Expired remote snapshot already absent: $n"
    else
      ob_info "Removing old remote snapshot beyond retention ($keep): $n"
      if ! timeout --signal=TERM --kill-after=5s "${OB_REMOTE_OPERATION_TIMEOUT_SECONDS}s" \
          rclone purge "$target" >/dev/null 2>&1; then
        ob_err "Could not remove expired remote snapshot '$n'; keeping the unpruned index for recovery."
        return 1
      fi
    fi
    local pruned_state
    pruned_state="$(ob_state_read | jq --arg n "$n" '.snapshots |= map(if .name==$n then .remote_pushed=false else . end)')" \
      && ob_state_write "$pruned_state"
  done <<< "$excess"
  local tmp index_target; tmp="$(mktemp)"
  echo "$retained" | jq . > "$tmp"
  ob_remote_index_valid "$tmp" || { rm -f -- "$tmp"; ob_err "Refusing to write an unsafe retained index."; return 1; }
  index_target="$(ob_remote_index_target "$base")" || { rm -f -- "$tmp"; return 1; }
  if ! timeout --signal=TERM --kill-after=5s "${OB_REMOTE_OPERATION_TIMEOUT_SECONDS}s" \
      rclone copyto "$tmp" "$index_target"; then
    rm -f "$tmp"
    ob_err "Could not write the pruned remote snapshot index."
    return 1
  fi
  rm -f "$tmp"
}

ob_remote_list() {
  ob_remote_configured || ob_die "No remote configured."
  local base; base="$(ob_remote_base)"
  local index
  index="$(ob_remote_read_index "$base")" || return 1
  printf '%s\n' "$index" \
    | jq -r '["NAME","CREATED","BASELINE","OMARCHY","SIZE"], (.snapshots[] | [.name,.created_at,(.baseline|tostring),.omarchy_version,((.size_bytes/1048576)|floor|tostring)+"MB"]) | @tsv' \
    | column -t -s $'\t'
}

ob_remote_pull() {
  local name="$1" dest="${2:-$OB_SNAPSHOTS_DIR/$name}"
  ob_require_snapshot_name "$name"
  ob_remote_configured || ob_die "No remote configured."
  local base target
  base="$(ob_remote_base)"
  target="$(ob_remote_snapshot_target "$base" "$name")" \
    || ob_die "Refusing unsafe remote snapshot target for '$name'."
  mkdir -p "$dest"
  ob_info "Downloading '$name' from $base/$name/ ..."
  timeout --signal=TERM --kill-after=5s "${OB_REMOTE_OPERATION_TIMEOUT_SECONDS}s" \
    rclone copy "$target" "$dest" \
      --include manifest.json --include checksums.sha256 --include payload.tar.zst \
    || ob_die "Download failed or exceeded its safety deadline: $name"
  [ -f "$dest/manifest.json" ] || ob_die "Download incomplete or snapshot not found on remote: $name"
  ob_info "Downloaded to $dest"
}
