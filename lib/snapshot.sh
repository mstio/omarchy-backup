#!/bin/bash
# Snapshot creation and slot-rotation bookkeeping (state.json).

ob_state_init_if_missing() {
  [ -f "$OB_STATE_FILE" ] && return 0
  jq -n '{schema_version:1, snapshots:[], last_doctor_run:null, last_doctor_status:null, last_seen_omarchy_version:null}' \
    > "$OB_STATE_FILE"
}

ob_state_read() { ob_state_init_if_missing; cat "$OB_STATE_FILE"; }

ob_state_write() {
  local new="$1"
  local tmp="$OB_STATE_FILE.tmp.$$"
  echo "$new" | jq . > "$tmp" && mv -- "$tmp" "$OB_STATE_FILE"
}

ob_state_snapshot_names() { ob_state_read | jq -r '.snapshots[].name'; }

ob_state_get_snapshot() {
  local name="$1"
  ob_state_read | jq --arg n "$name" '.snapshots[] | select(.name==$n)'
}

ob_state_baseline_name() {
  ob_state_read | jq -r '.snapshots[] | select(.baseline==true) | .name' | head -n1
}

# Decide which existing slot to replace when at capacity. Prints a name, or
# nothing if the caller should abort. Honors $OB_REPLACE_NAME if set.
ob_pick_slot_to_replace() {
  local state="$1"
  if [ -n "${OB_REPLACE_NAME:-}" ]; then
    echo "$OB_REPLACE_NAME"
    return 0
  fi
  local count
  count="$(echo "$state" | jq '.snapshots | length')"
  if [ "$count" -lt "$OB_MAX_SNAPSHOTS" ]; then
    return 0
  fi
  if [ -t 0 ] && [ "${OB_AUTO_MODE:-false}" != "true" ]; then
    echo "Already have $OB_MAX_SNAPSHOTS snapshots (max):" >&2
    echo "$state" | jq -r '.snapshots[] | "  \(.name)  created \(.created_at)  baseline=\(.baseline)"' >&2
    local ans
    read -r -p "Which snapshot should be replaced? (name, or 'abort'): " ans
    if [ -z "$ans" ] || [ "$ans" = "abort" ]; then
      return 1
    fi
    echo "$ans"
    return 0
  fi
  # Non-interactive: replace the oldest non-baseline snapshot.
  local victim
  victim="$(echo "$state" | jq -r '[.snapshots[] | select(.baseline==false)] | sort_by(.created_at) | .[0].name // empty')"
  if [ -z "$victim" ]; then
    victim="$(echo "$state" | jq -r '.snapshots | sort_by(.created_at) | .[0].name')"
    ob_warn "All existing snapshots are marked baseline (unexpected); replacing oldest: $victim"
  fi
  echo "$victim"
}

ob_snapshot_create() {
  ob_ensure_dirs
  ob_load_config
  ob_read_path_rules
  ob_state_init_if_missing

  local name="${OB_SNAPSHOT_NAME:-snapshot-$(date '+%Y%m%d-%H%M%S')}"
  local mark_baseline="${OB_MARK_BASELINE:-false}"

  local state; state="$(ob_state_read)"
  if echo "$state" | jq -e --arg n "$name" '.snapshots[] | select(.name==$n)' >/dev/null; then
    ob_die "A snapshot named '$name' already exists. Choose another name or restore/replace it explicitly."
  fi

  local victim=""
  local count; count="$(echo "$state" | jq '.snapshots | length')"
  if [ "$count" -ge "$OB_MAX_SNAPSHOTS" ]; then
    victim="$(ob_pick_slot_to_replace "$state")" || ob_die "Aborted: no slot chosen to replace."
    if [ -z "$victim" ]; then
      ob_die "Aborted: no slot chosen to replace."
    fi
    if ! echo "$state" | jq -e --arg n "$victim" '.snapshots[] | select(.name==$n)' >/dev/null; then
      ob_die "No such snapshot to replace: $victim"
    fi
    ob_info "Replacing existing snapshot slot: $victim"
  fi

  ob_info "Creating snapshot '$name'..."
  local snap_dir="$OB_SNAPSHOTS_DIR/$name"
  mkdir -p "$snap_dir"

  local OB_SKIPPED_LARGE=() OB_SKIPPED_SECRET=()
  ob_resolve_included_files
  ob_info "Resolved ${#OB_RESOLVED_FILES[@]} files to include (${#OB_SKIPPED_LARGE[@]} skipped: too large, ${#OB_SKIPPED_SECRET[@]} skipped: looked like secrets)."

  # Build the payload tar.zst with paths relative to $HOME.
  local filelist; filelist="$(mktemp)"
  local f
  for f in "${OB_RESOLVED_FILES[@]}"; do
    printf '%s\0' "${f#"$HOME"/}"
  done > "$filelist"
  local payload="$snap_dir/payload.tar.zst"
  if [ -s "$filelist" ]; then
    tar -C "$HOME" --null -T "$filelist" -cf - 2>/dev/null | zstd -q -19 -T0 -o "$payload"
  else
    tar -C "$HOME" --files-from=/dev/null -cf - | zstd -q -o "$payload"
  fi
  rm -f "$filelist"

  ob_write_checksums "$snap_dir/checksums.sha256" "${OB_RESOLVED_FILES[@]}"

  local inventory; inventory="$(ob_inv_all)"
  local payload_sha payload_size
  payload_sha="$(sha256sum -- "$payload" | awk '{print $1}')"
  payload_size="$(stat -c '%s' -- "$payload")"

  local skipped_large_json skipped_secret_json
  skipped_large_json="$(printf '%s\n' "${OB_SKIPPED_LARGE[@]:-}" | jq -R 'select(length>0)' | jq -s .)"
  skipped_secret_json="$(printf '%s\n' "${OB_SKIPPED_SECRET[@]:-}" | jq -R 'select(length>0)' | jq -s .)"

  local manifest
  manifest="$(jq -n \
    --arg schema_version "1" \
    --arg name "$name" \
    --arg created_at "$(date -Iseconds)" \
    --arg hostname "$(ob_hostname)" \
    --arg tool_version "$OB_VERSION" \
    --argjson baseline "$mark_baseline" \
    --argjson inventory "$inventory" \
    --argjson skipped_large "$skipped_large_json" \
    --argjson skipped_secret "$skipped_secret_json" \
    --arg payload_file "payload.tar.zst" \
    --arg payload_sha256 "$payload_sha" \
    --argjson payload_size "$payload_size" \
    --argjson file_count "${#OB_RESOLVED_FILES[@]}" \
    '{
      schema_version: ($schema_version|tonumber),
      name:$name, created_at:$created_at, hostname:$hostname, tool_version:$tool_version,
      baseline:$baseline,
      omarchy_version: $inventory.omarchy_version,
      kernel: $inventory.kernel,
      hyprland_version: $inventory.hyprland_version,
      packages: $inventory.packages,
      plugins: $inventory.plugins,
      systemd_user_units: $inventory.systemd_user_units,
      skipped_large_files:$skipped_large,
      skipped_secret_files:$skipped_secret,
      payload: {file:$payload_file, sha256:$payload_sha256, size_bytes:$payload_size},
      file_count:$file_count
    }')"
  echo "$manifest" | jq . > "$snap_dir/manifest.json"

  # Remove replaced slot, if any, then update state.json.
  if [ -n "$victim" ]; then
    rm -rf -- "${OB_SNAPSHOTS_DIR:?}/$victim"
    state="$(echo "$state" | jq --arg n "$victim" '.snapshots |= map(select(.name!=$n))')"
  fi
  if [ "$mark_baseline" = "true" ]; then
    state="$(echo "$state" | jq '.snapshots |= map(.baseline=false)')"
  fi
  local entry
  entry="$(jq -n --arg name "$name" --arg created_at "$(echo "$manifest" | jq -r .created_at)" \
    --arg path "$snap_dir" --argjson baseline "$mark_baseline" \
    --arg omarchy_version "$(echo "$manifest" | jq -r .omarchy_version)" \
    --argjson size_bytes "$payload_size" \
    '{name:$name, created_at:$created_at, path:$path, baseline:$baseline, omarchy_version:$omarchy_version, size_bytes:$size_bytes}')"
  state="$(echo "$state" | jq --argjson e "$entry" '.snapshots += [$e]')"
  ob_state_write "$state"

  ob_info "Snapshot '$name' created ($((payload_size / 1024 / 1024))MB payload, ${#OB_RESOLVED_FILES[@]} files)."
  if [ "${#OB_SKIPPED_LARGE[@]}" -gt 0 ]; then
    ob_warn "Skipped ${#OB_SKIPPED_LARGE[@]} file(s) over ${OB_CFG_MAX_FILE_SIZE_MB}MB (see manifest.json: skipped_large_files)."
  fi
  if [ "${#OB_SKIPPED_SECRET[@]}" -gt 0 ]; then
    ob_warn "Skipped ${#OB_SKIPPED_SECRET[@]} file(s) that looked like secrets (see manifest.json: skipped_secret_files)."
  fi
  if [ "$mark_baseline" = "true" ]; then
    ob_info "Marked '$name' as baseline."
  fi
  echo "$name"
}

ob_snapshot_list() {
  ob_state_init_if_missing
  ob_state_read | jq -r '
    ["NAME","CREATED","BASELINE","OMARCHY","SIZE"],
    (.snapshots | sort_by(.created_at) | reverse[] |
      [.name, .created_at, (.baseline|tostring), .omarchy_version, ((.size_bytes/1048576)|floor|tostring)+"MB"])
    | @tsv' | column -t -s $'\t'
}

ob_snapshot_show() {
  local name="$1"
  local dir="$OB_SNAPSHOTS_DIR/$name"
  [ -f "$dir/manifest.json" ] || ob_die "No such snapshot: $name"
  jq . "$dir/manifest.json"
}
