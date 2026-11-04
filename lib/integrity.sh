#!/bin/bash
# Integrity of the backup destination -- "never trust your input".
#
# The destination (a cloud drive, a NAS, a mounted share) and everything in a
# snapshot is untrusted: whoever can write there can replace a payload AND
# recompute the checksums inside manifest.json. Three independent layers:
#
#   1. Hash ledger (this machine only, never uploaded): at push time the
#      remote files of every snapshot are recorded -- with the backend's own
#      MD5 where it offers one without downloading (rclone lsjson --hash,
#      e.g. Google Drive), otherwise size + modification time. Automatic runs
#      and `doctor` compare the destination with it; any change, addition or
#      removal is a critical alert. Trust only holds while this machine (and
#      its ledger) lives -- after a reinstall, layer 2 takes over.
#   2. Signatures: manifest.json (payload sha256, checksums sha256) is signed
#      with an SSH key (`ssh-keygen -Y sign`, no new dependency). The trust
#      anchor never comes from the backup itself: a local allowed-signers
#      file or the public signing keys of a GitHub account.
#   3. Restore review: before writing anything, restore lists the
#      security-relevant content (code that runs: scripts, units, hooks, shell
#      and agent configuration, ...) and asks for confirmation.
#
# The trust decision stays with the user: an unverified snapshot can still be
# restored, but only loudly and after an explicit confirmation.

OB_LEDGER_FILE="$OB_DATA_DIR/integrity-ledger.json"
OB_INTEGRITY_STATUS_FILE="$OB_DATA_DIR/integrity-status.json"
OB_SIG_NAMESPACE="omarchy-backup"
OB_SIG_PRINCIPAL="omarchy-backup"

# --- 1. hash ledger ----------------------------------------------------------

ob_ledger_read() {
  if [ -f "$OB_LEDGER_FILE" ] && jq -e '.snapshots' "$OB_LEDGER_FILE" >/dev/null 2>&1; then
    cat "$OB_LEDGER_FILE"
  else
    echo '{"schema_version":1,"snapshots":{},"base":null}'
  fi
}

# The ledger remembers when it came into being: snapshots uploaded before
# that can only be "unrecorded"; anything uploaded later and still missing
# from it is a problem.
ob_ledger_write() {
  local tmp="$OB_LEDGER_FILE.tmp.$$"
  printf '%s\n' "$1" | jq --argjson now "$(date +%s)" '.created_epoch = (.created_epoch // $now)' > "$tmp" 2>/dev/null \
    || { rm -f -- "$tmp"; return 1; }
  chmod 600 -- "$tmp" 2>/dev/null
  mv -f -- "$tmp" "$OB_LEDGER_FILE"
}

# Test hooks are honoured only with OMARCHY_BACKUP_TEST_MODE=true (set by
# tests/run-tests.sh), so the environment alone never weakens a check.
ob_test_mode() { [ "${OMARCHY_BACKUP_TEST_MODE:-false}" = true ]; }

# Where to list the destination and how strong that listing is.
#   strong: content hashes from the backend (rclone remote), or computed from
#           a local, non-FUSE folder (cheap: local disk).
#   weak:   size + modification time only -- a FUSE mount (rclone mount of a
#           cloud drive) would have to download every file to hash it.
# Prints "<rclone spec of the host folder>\t<strong|weak>".
ob_integrity_target() {
  if [ -n "${OB_CFG_REMOTE_NAME:-}" ]; then
    printf '%s\tstrong\n' "$(ob_remote_base)"
  elif [ -n "${OB_CFG_INTEGRITY_RCLONE_REMOTE:-}" ]; then
    printf '%s/%s\tstrong\n' "${OB_CFG_INTEGRITY_RCLONE_REMOTE%/}" "$(ob_hostname)"
  else
    local fstype
    fstype="$(stat -f -c %T -- "${OB_CFG_REMOTE_PATH%/}" 2>/dev/null)"
    if { ob_test_mode && [ "${OMARCHY_BACKUP_TEST_WEAK_INTEGRITY:-false}" = true ]; } || [[ "$fstype" == fuse* ]]; then
      printf '%s\tweak\n' "$(ob_remote_base)"
    else
      printf '%s\tstrong\n' "$(ob_remote_base)"
    fi
  fi
}

# ob_integrity_list <spec> <mode> -> JSON {file:{size,md5,mtime}} of the
# files directly in <spec>. rc 3: folder does not exist; rc 1: other error.
# Times are listed in UTC, so a DST or time zone change is no "change".
ob_integrity_list() {
  local spec="$1" mode="$2" out rc
  local -a args=(lsjson --files-only --no-mimetype)
  [ "$mode" = strong ] && args+=(--hash --hash-type md5)
  out="$(TZ=UTC timeout --signal=TERM --kill-after=5s "${OB_REMOTE_INDEX_TIMEOUT_SECONDS:-60}s" \
    rclone "${args[@]}" "$spec" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 3 ] && return 3
    return 1
  fi
  printf '%s' "$out" | jq -c 'map({(.Name): {size: .Size, md5: (.Hashes.md5 // ""), mtime: (.ModTime[0:19])}}) | add // {}'
}

ob_integrity_list_dirs() {  # <spec> -> folder names, one per line
  timeout --signal=TERM --kill-after=5s "${OB_REMOTE_INDEX_TIMEOUT_SECONDS:-60}s" \
    rclone lsf --dirs-only "$1" 2>/dev/null | sed 's|/$||'
}

# Verifies a remote entry against the local file this machine just
# uploaded (md5 where the backend has one, else the size).
ob_integrity_entry_matches() {  # <entry json> <local file>
  local entry="$1" f="$2" rmd5 rsize
  [ -n "$entry" ] && [ "$entry" != null ] || return 1
  rmd5="$(printf '%s' "$entry" | jq -r '.md5 // ""')"
  rsize="$(printf '%s' "$entry" | jq -r '.size // -1')"
  [ "$rsize" = "$(stat -c %s -- "$f" 2>/dev/null)" ] || return 1
  [ -z "$rmd5" ] || [ "$rmd5" = "$(md5sum -- "$f" | awk '{print $1}')" ]
}

# Records the files of one snapshot that this machine just uploaded -- and
# only those: anything else in that folder stays "added" (a problem), even
# if it was planted before the upload.
ob_ledger_record() {  # <snapshot name>
  local name="$1" spec mode listing f entry recorded='{}'
  IFS=$'\t' read -r spec mode < <(ob_integrity_target)
  listing="$(ob_integrity_list "$spec/$name" "$mode")" || {
    ob_warn "Could not list '$name' on the destination; its integrity is not recorded."
    return 1
  }
  for f in manifest.json manifest.json.sig checksums.sha256 payload.tar.zst; do
    [ -f "$OB_SNAPSHOTS_DIR/$name/$f" ] || continue
    entry="$(printf '%s' "$listing" | jq -c --arg f "$f" '.[$f] // null')"
    if ! ob_integrity_entry_matches "$entry" "$OB_SNAPSHOTS_DIR/$name/$f"; then
      ob_err "The destination's $name/$f does not match what was just uploaded; not recorded."
      return 1
    fi
    recorded="$(printf '%s' "$recorded" | jq -c --arg f "$f" --argjson e "$entry" '.[$f] = $e')"
  done
  ob_ledger_write "$(ob_ledger_read | jq --arg n "$name" --arg m "$mode" --arg t "$(date -Iseconds)" \
    --argjson files "$recorded" '.snapshots[$n] = {mode:$m, recorded_at:$t, files:$files}')"
}

# `integrity record <name>`: the user vouches for an upload from before the
# ledger existed -- everything currently in that folder is recorded.
# `integrity record <name>`: the user vouches for an upload from before the
# ledger existed. With a local copy (the one a dry run checked) only the
# snapshot's four files are recorded, and only if the destination's match
# it -- anything else in that folder stays a problem. Without a local copy
# the current remote listing is trusted as is, which needs --yes.
ob_ledger_adopt() {  # <snapshot name>
  local name="$1" spec mode listing f entry recorded='{}' extra
  IFS=$'\t' read -r spec mode < <(ob_integrity_target)
  listing="$(ob_integrity_list "$spec/$name" "$mode")" || { ob_err "Could not list '$name' on the destination."; return 1; }
  if [ -f "$OB_SNAPSHOTS_DIR/$name/manifest.json" ]; then
    for f in manifest.json manifest.json.sig checksums.sha256 payload.tar.zst; do
      [ -f "$OB_SNAPSHOTS_DIR/$name/$f" ] || continue
      entry="$(printf '%s' "$listing" | jq -c --arg f "$f" '.[$f] // null')"
      if ! ob_integrity_entry_matches "$entry" "$OB_SNAPSHOTS_DIR/$name/$f"; then
        ob_err "The destination's $name/$f differs from the local copy; not adopted."
        return 1
      fi
      recorded="$(printf '%s' "$recorded" | jq -c --arg f "$f" --argjson e "$entry" '.[$f] = $e')"
    done
    extra="$(printf '%s' "$listing" | jq -r --argjson r "$recorded" 'keys - ($r | keys) | .[]')"
    [ -z "$extra" ] || ob_warn "Not adopted (stay problems until removed from the destination): $(printf '%s ' $extra)"
  else
    ob_warn "No local copy of '$name' to compare with: this trusts whatever the destination holds right now: $(printf '%s' "$listing" | jq -r 'keys | join(", ")')."
    if [ "${OB_RESTORE_YES:-false}" != true ]; then
      ob_err "Not adopted. Re-run with --yes to trust that remote content as is."
      return 1
    fi
    recorded="$listing"
  fi
  ob_ledger_write "$(ob_ledger_read | jq --arg n "$name" --arg m "$mode" --arg t "$(date -Iseconds)" \
    --argjson files "$recorded" '.snapshots[$n] = {mode:$m, recorded_at:$t, files:$files, adopted:true}')"
}

# Leftovers of interrupted restores/pulls (older than a day; current ones
# are never touched).
ob_sweep_stale_staging() {
  [ -d "$OB_DATA_DIR" ] && find "${OB_DATA_DIR:?}" -mindepth 1 -maxdepth 1 -type d -name '.restore-stage.*' -mmin +1440 \
    -exec rm -rf -- {} + 2>/dev/null
  [ -d "$OB_SNAPSHOTS_DIR" ] && find "${OB_SNAPSHOTS_DIR:?}" -mindepth 1 -maxdepth 1 -type d -name '.*.pull.*' -mmin +1440 \
    -exec rm -rf -- {} + 2>/dev/null
  # Restore review files (several MB per fresh install) after 30 days.
  [ -d "$OB_DATA_DIR" ] && find "${OB_DATA_DIR:?}" -mindepth 1 -maxdepth 1 -type f -name 'restore-review-*.txt' -mtime +30 \
    -delete 2>/dev/null
  return 0
}

# Seconds since epoch of an ISO date (0 if unparsable).
ob_epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }

# One file this machine just wrote into the host folder (index.json, the
# tool copy, RECOVERY.md and their signatures): verified against the local
# copy, then only that entry is updated. Never re-baselines the folder.
ob_ledger_note_base() {  # <remote file name> <local file>
  local fname="$1" local_file="$2" spec mode listing entry
  IFS=$'\t' read -r spec mode < <(ob_integrity_target)
  listing="$(ob_integrity_list "$spec" "$mode")" || return 1
  entry="$(printf '%s' "$listing" | jq -c --arg f "$fname" '.[$f] // null')"
  if ! ob_integrity_entry_matches "$entry" "$local_file"; then
    ob_warn "The destination's $fname does not match what was just uploaded; not recorded."
    return 1
  fi
  ob_ledger_write "$(ob_ledger_read | jq --arg f "$fname" --arg m "$mode" --argjson e "$entry" \
    '.base = ((.base // {mode:$m, files:{}}) | .mode = $m | .files[$f] = $e)')"
}

ob_ledger_forget() {  # <snapshot name> (pruned by retention, or by the user)
  ob_ledger_write "$(ob_ledger_read | jq --arg n "$1" 'del(.snapshots[$n])')"
}

ob_ledger_has_entries() {
  [ "$(ob_ledger_read | jq '(.snapshots | length) + (.base.files // {} | length)')" -gt 0 ]
}

# Compares two {file:{size,md5,mtime}} maps; prints "<kind>: <prefix><file>".
ob_integrity_diff() {  # <expected json> <actual json> <prefix>
  jq -rn --argjson e "$1" --argjson a "$2" --arg p "$3" '
    def same($x; $y):
      if ($x.md5 // "") != "" and ($y.md5 // "") != "" then $x.md5 == $y.md5 and $x.size == $y.size
      else $x.size == $y.size and $x.mtime == $y.mtime end;
    (($e | keys[]) as $k
      | if ($a | has($k) | not) then "removed: \($p)\($k)"
        elif same($e[$k]; $a[$k]) | not then "changed: \($p)\($k)"
        else empty end),
    ((($a | keys) - ($e | keys))[] | "added: \($p)\(.)")'
}

# ob_integrity_check [--notify]
# rc 0: destination matches the ledger; 1: tampering/corruption found (the
# exact files are printed); 2: could not check (destination unavailable).
# The result is cached for `status` (no network there).
ob_integrity_check() {
  local notify=false
  [ "${1:-}" = "--notify" ] && notify=true
  local spec mode ledger problems="" unrecorded="" n files out rc
  IFS=$'\t' read -r spec mode < <(ob_integrity_target)
  ledger="$(ob_ledger_read)"
  for n in $(printf '%s' "$ledger" | jq -r '.snapshots | keys[]'); do
    ob_snapshot_name_valid "$n" || continue
    out="$(ob_integrity_list "$spec/$n" "$mode")"
    rc=$?
    if [ "$rc" -eq 3 ]; then
      problems+="removed: $n/ (whole snapshot)"$'\n'
      continue
    elif [ "$rc" -ne 0 ]; then
      return 2
    fi
    files="$(printf '%s' "$ledger" | jq -c --arg n "$n" '.snapshots[$n].files')"
    problems+="$(ob_integrity_diff "$files" "$out" "$n/")"$'\n'
  done
  if [ "$(printf '%s' "$ledger" | jq '.base != null')" = true ]; then
    out="$(ob_integrity_list "$spec" "$mode")" || return 2
    problems+="$(ob_integrity_diff "$(printf '%s' "$ledger" | jq -c '.base.files')" "$out" "")"$'\n'
  fi
  # Folders nobody recorded: planted snapshots, or uploads from before the
  # ledger existed (`omarchy-backup integrity record <name>` adopts those
  # after a manual review).
  # Older uploads are in this machine's state or in the remote index (which
  # the ledger itself covers once a push recorded it).
  local d known indexed state ledger_born last_push created
  known="$(printf '%s' "$ledger" | jq -r '.snapshots | keys[]')"
  indexed="$(ob_remote_read_index "$(ob_remote_base)" 2>/dev/null | jq -c '[.snapshots[]? | {name, created_at}]' 2>/dev/null)"
  [ -n "$indexed" ] || indexed='[]'
  state="$(ob_state_read)"
  ledger_born="$(printf '%s' "$ledger" | jq -r '.created_epoch // 0')"
  last_push="$(printf '%s' "$state" | jq -r '.last_push_epoch // 0')"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    printf '%s\n' "$known" | grep -qxF -- "$d" && continue
    created="$(jq -rn --argjson i "$indexed" --argjson s "$state" --arg n "$d" \
      '([$s.snapshots[]? | select(.name==$n and .remote_pushed==true) | .created_at] + [$i[] | select(.name==$n) | .created_at]) | first // ""')"
    if [ -n "$created" ]; then
      # Listed as uploaded: fine only if that was before the ledger existed.
      if [ "$ledger_born" -gt 0 ] && [ "$(ob_epoch "$created")" -ge "$ledger_born" ]; then
        problems+="added: $d/ (listed as uploaded after the ledger existed, but never recorded)"$'\n'
      else
        unrecorded+="$d"$'\n'
      fi
    elif created="$(printf '%s' "$state" | jq -r --arg n "$d" '.snapshots[] | select(.name==$n) | .created_at' 2>/dev/null)" \
        && [ -n "$created" ] && [ "$(ob_epoch "$created")" -gt "$last_push" ]; then
      # A local snapshot newer than the last good upload whose own upload
      # did not finish: its retry overwrites it and records only the files
      # this machine wrote.
      continue
    else
      problems+="added: $d/ (unknown folder)"$'\n'
    fi
  done < <(ob_integrity_list_dirs "$spec")
  problems="$(printf '%s' "$problems" | sed '/^$/d' | sort -u)"
  unrecorded="$(printf '%s' "$unrecorded" | sed '/^$/d')"
  # Alert when the set of problems differs from the last one alerted about,
  # not on every run while it persists (status and doctor stay red).
  local notified="" send=false
  [ -f "$OB_INTEGRITY_STATUS_FILE" ] && notified="$(jq -r '.notified[]?' "$OB_INTEGRITY_STATUS_FILE" 2>/dev/null | sort -u)"
  if [ -n "$problems" ] && [ "$notify" = true ] && [ "$problems" != "$notified" ]; then
    send=true; notified="$problems"
  fi
  [ -z "$problems" ] && notified=""
  jq -n --arg t "$(date -Iseconds)" --arg m "$mode" --arg p "$problems" --arg u "$unrecorded" --arg nf "$notified" \
    '{checked_at:$t, mode:$m, problems:($p | split("\n") | map(select(length>0))),
      unrecorded:($u | split("\n") | map(select(length>0))),
      notified:($nf | split("\n") | map(select(length>0)))}' > "$OB_INTEGRITY_STATUS_FILE.tmp.$$" \
    && mv -f -- "$OB_INTEGRITY_STATUS_FILE.tmp.$$" "$OB_INTEGRITY_STATUS_FILE"
  if [ "$send" = true ]; then
    ob_notify "omarchy-backup: backup destination was modified" \
      "Files of uploaded snapshots changed outside this machine. Do not restore from them; run 'omarchy-backup doctor'." critical
  fi
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems"
    return 1
  fi
  return 0
}

# CLI: omarchy-backup integrity check|record <name>|status
ob_integrity_cmd() {
  local sub="${1:-check}"
  [ "${2:-}" = "--yes" ] || [ "${3:-}" = "--yes" ] && OB_RESTORE_YES=true
  ob_ensure_dirs; ob_load_config; ob_state_init_if_missing
  ob_remote_configured || ob_die "No remote backup destination configured."
  case "$sub" in
    check)
      local out rc
      out="$(ob_integrity_check)"; rc=$?
      case "$rc" in
        0) ob_info "Destination matches the integrity ledger ($(jq -r .mode "$OB_INTEGRITY_STATUS_FILE") check)."
           jq -r '.unrecorded[] | "Not in the ledger (uploaded before it existed): \(.) -- review, then: omarchy-backup integrity record \(.)"' "$OB_INTEGRITY_STATUS_FILE" ;;
        1) ob_err "Destination does NOT match the integrity ledger:"; printf '%s\n' "$out" | sed 's/^/  /' ;;
        *) ob_err "Could not check the destination (unavailable?)." ;;
      esac
      return "$rc" ;;
    record)
      [ $# -ge 2 ] || ob_die "Usage: omarchy-backup integrity record <snapshot-name> [--yes]"
      ob_require_snapshot_name "$2"
      ob_ledger_adopt "$2" && ob_info "Recorded '$2' in the integrity ledger." ;;
    forget)
      [ $# -ge 2 ] || ob_die "Usage: omarchy-backup integrity forget <snapshot-name>"
      ob_require_snapshot_name "$2"
      ob_ledger_forget "$2" && ob_info "Removed '$2' from the integrity ledger. Delete that folder on the destination if it is still there." ;;
    reset)
      ob_warn "This forgets everything the ledger knows: the next push records the destination anew. Only after you cleaned up the destination."
      if [ "${OB_RESTORE_YES:-false}" = true ] || ob_confirm "Reset the integrity ledger?"; then
        ob_ledger_write '{"schema_version":1,"snapshots":{},"base":null}' && rm -f -- "$OB_INTEGRITY_STATUS_FILE"
        ob_info "Integrity ledger reset."
      else
        ob_die "Not reset (non-interactive: --yes)."
      fi ;;
    *) ob_die "Usage: omarchy-backup integrity check|record <name>|forget <name>|reset [--yes]" ;;
  esac
}

# --- 2. signatures -------------------------------------------------------------

ob_sig_key() {
  [ -n "${OB_CFG_SIGNING_KEY:-}" ] || return 1
  ob_expand_path "$OB_CFG_SIGNING_KEY"
}

# Signs <file> -> <file>.sig. Without a configured key it does nothing
# (rc 0, no .sig); a failing key is reported (rc 1).
ob_sig_sign_file() {
  local f="$1" key
  rm -f -- "$f.sig"
  key="$(ob_sig_key)" || return 0
  if [ ! -r "$key" ]; then
    ob_warn "Signing key $key is not readable; $(basename -- "$f") left unsigned."
    return 1
  fi
  if ! ssh-keygen -Y sign -q -f "$key" -n "$OB_SIG_NAMESPACE" "$f" </dev/null >/dev/null 2>&1 \
      || [ ! -s "$f.sig" ]; then
    rm -f -- "$f.sig"
    ob_warn "Could not sign $(basename -- "$f") with $key (passphrase-protected key in a non-interactive run?); left unsigned."
    return 1
  fi
  chmod 600 -- "$f.sig" 2>/dev/null || true
}

# Snapshot manifest. Never fails the snapshot (local first).
ob_sig_sign() { ob_sig_sign_file "$1/manifest.json"; }

ob_sig_pubkey_line_valid() {  # "<type> <base64>" (comment stripped)
  [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+={0,3}$ ]]
}

# Normalizes public keys from a file or stdin into allowed-signers lines for
# our principal/namespace (any principal or option already present is
# dropped: only the key itself is trusted, for this purpose only).
ob_sig_keys_to_allowed() {
  local line tok i k
  while IFS= read -r line; do
    line="${line%%#*}"
    read -r -a tok <<< "$line"
    for ((i = 0; i < ${#tok[@]}; i++)); do
      k="${tok[$i]} ${tok[$((i + 1))]:-}"
      if ob_sig_pubkey_line_valid "$k"; then
        printf '%s namespaces="%s" %s\n' "$OB_SIG_PRINCIPAL" "$OB_SIG_NAMESPACE" "$k"
        break
      fi
    done
  done
}

# Builds the allowed-signers file from the configured trust anchors (never
# from the snapshot): OB_SIG_ALLOWED_FILE / OB_CFG_ALLOWED_SIGNERS (local
# file), OB_SIG_GITHUB / OB_CFG_SIGNER_GITHUB (GitHub user's public signing
# keys). Sets OB_SIG_ANCHOR to a description. rc 1: no anchor configured,
# rc 2: anchor configured but unusable (network, no keys).
ob_sig_build_allowed() {
  local out="$1" file user json
  : > "$out"
  OB_SIG_ANCHOR=""
  file="${OB_SIG_ALLOWED_FILE:-${OB_CFG_ALLOWED_SIGNERS:-}}"
  user="${OB_SIG_GITHUB:-${OB_CFG_SIGNER_GITHUB:-}}"
  [ -n "$file" ] || [ -n "$user" ] || return 1
  if [ -n "$file" ]; then
    file="$(ob_expand_path "$file")"
    [ -r "$file" ] || { OB_SIG_ANCHOR="allowed-signers file $file (not readable)"; return 2; }
    ob_sig_keys_to_allowed < "$file" >> "$out"
    OB_SIG_ANCHOR="allowed-signers file $file"
  fi
  if [ -n "$user" ]; then
    if ! [[ "$user" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]]; then
      OB_SIG_ANCHOR="GitHub user '$user' (invalid name)"; return 2
    fi
    local api="https://api.github.com"
    if ob_test_mode && [[ "${OMARCHY_BACKUP_GITHUB_API:-}" =~ ^(file://|http://127\.0\.0\.1[:/]) ]]; then
      api="$OMARCHY_BACKUP_GITHUB_API"
    fi
    if json="$(curl -fsS --max-time 15 -H 'Accept: application/vnd.github+json' \
        "$api/users/$user/ssh_signing_keys" 2>/dev/null)" \
        && printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
      printf '%s' "$json" | jq -r '.[].key // empty' | ob_sig_keys_to_allowed >> "$out"
      OB_SIG_ANCHOR="${OB_SIG_ANCHOR:+$OB_SIG_ANCHOR + }GitHub signing keys of '$user'"
    else
      OB_SIG_ANCHOR="${OB_SIG_ANCHOR:+$OB_SIG_ANCHOR + }GitHub signing keys of '$user' (could not be fetched)"
      [ -s "$out" ] || return 2
    fi
  fi
  [ -s "$out" ] || return 2
  return 0
}

# ob_sig_verify <snapshot dir> -> sets OB_SIG_RESULT
# (verified|unsigned|invalid|no-anchor|anchor-error) and OB_SIG_DETAIL.
ob_sig_verify() {
  local dir="$1" allowed out rc
  OB_SIG_RESULT="" OB_SIG_DETAIL=""
  allowed="$(mktemp)" || return 1
  ob_sig_build_allowed "$allowed"; rc=$?
  if [ ! -f "$dir/manifest.json.sig" ]; then
    OB_SIG_RESULT=unsigned; OB_SIG_DETAIL="the snapshot carries no signature (manifest.json.sig)"
  elif [ "$rc" -eq 1 ]; then
    OB_SIG_RESULT=no-anchor; OB_SIG_DETAIL="no trust anchor configured (OB_CFG_SIGNER_GITHUB / OB_CFG_ALLOWED_SIGNERS, or --signer-github / --allowed-signers)"
  elif [ "$rc" -ne 0 ]; then
    OB_SIG_RESULT=anchor-error; OB_SIG_DETAIL="trust anchor unusable: $OB_SIG_ANCHOR"
  elif out="$(ssh-keygen -Y verify -f "$allowed" -I "$OB_SIG_PRINCIPAL" -n "$OB_SIG_NAMESPACE" \
        -s "$dir/manifest.json.sig" < "$dir/manifest.json" 2>&1)"; then
    OB_SIG_RESULT=verified
    OB_SIG_DETAIL="$(printf '%s' "$out" | grep -o '[A-Z0-9-]* key SHA256:[A-Za-z0-9+/=]*' | head -n 1) (trusted via $OB_SIG_ANCHOR)"
  else
    OB_SIG_RESULT=invalid; OB_SIG_DETAIL="signature does not verify against $OB_SIG_ANCHOR (tampered, or signed by an unknown key)"
  fi
  rm -f -- "$allowed"
  # A valid signature covers manifest.json; manifest.json covers the rest.
  if [ "$OB_SIG_RESULT" = verified ]; then
    local want have
    want="$(jq -r '.checksums_sha256 // ""' "$dir/manifest.json" 2>/dev/null)"
    if [ -n "$want" ]; then
      have="$(sha256sum -- "$dir/checksums.sha256" 2>/dev/null | awk '{print $1}')"
      if [ "$want" != "$have" ]; then
        OB_SIG_RESULT=invalid; OB_SIG_DETAIL="checksums.sha256 does not match the signed manifest"
      fi
    fi
  fi
  return 0
}

# ob_sig_gate <snapshot dir> <what> -> 0 continue, 1 stop.
# Verified: say so. Anything else: loud warning, then continue only with
# --accept-unverified (OB_ACCEPT_UNVERIFIED=true), an interactive "yes", or
# in a dry run (which writes nothing).
ob_sig_gate() {
  local dir="$1" what="$2"
  ob_sig_verify "$dir"
  if [ "$OB_SIG_RESULT" = verified ]; then
    ob_info "Signature OK: $OB_SIG_DETAIL."
    return 0
  fi
  ob_warn "############################################################"
  ob_warn "UNVERIFIED SNAPSHOT ($OB_SIG_RESULT): $OB_SIG_DETAIL."
  ob_warn "Its content may have been changed by whoever can write to the backup destination."
  ob_warn "############################################################"
  if [ "${OB_ACCEPT_UNVERIFIED:-false}" = true ]; then
    ob_warn "Continuing with $what because --accept-unverified was given."
    return 0
  fi
  if [ "${OB_DRY_RUN:-false}" = true ]; then
    ob_warn "Dry run: continuing to show what would happen; a real run needs your confirmation."
    return 0
  fi
  if ob_confirm "Continue with $what of this UNVERIFIED snapshot anyway?"; then
    ob_warn "Continuing with an unverified snapshot on your explicit confirmation."
    return 0
  fi
  ob_err "Stopped: $what of an unverified snapshot needs your confirmation (interactive) or --accept-unverified."
  return 1
}

# --- 3. restore review ---------------------------------------------------------

# Every file the restore would add or change is listed, grouped per folder,
# and shown -- except pure data (images, fonts). Two tiers: what runs as code
# or steers what runs is shown in full (up to 200 lines per file), anything
# else as an 8-line excerpt or 40-line diff. The complete review is always
# written to $OB_DATA_DIR/restore-review-<name>-<time>.txt; on a terminal a
# long one opens in a pager.
OB_REVIEW_DATA_ONLY_EXT='png|jpg|jpeg|gif|webp|avif|bmp|ico|svg|ttf|otf|woff|woff2'
OB_REVIEW_SENSITIVE_GLOBS=(
  ".local/bin/*" ".config/systemd/user/*" ".config/omarchy/hooks/*" ".config/omarchy/plugins/*"
  ".config/omarchy/extensions/*" ".config/omarchy/themes/*" ".config/omarchy/lock-designs/*"
  ".config/omarchy/branding/*" ".config/hypr/*" ".config/autostart/*" ".local/share/applications/*"
  ".config/environment.d/*" ".config/uwsm/*" ".config/mimeapps.list"
  ".bashrc" ".bash_profile" ".bash_login" ".bash_logout" ".bash_aliases" ".profile" ".xprofile" ".xinitrc"
  ".zshrc" ".zprofile" ".zshenv" ".zlogin" ".config/fish/*" ".config/direnv/*"
  ".config/git/*" ".gitconfig" ".ssh/*" ".gnupg/*" ".config/gh/*" ".aws/*" ".npmrc" ".config/pip/*" ".cargo/config*"
  ".config/ai-agents/*" ".claude/*" ".codex/*" ".gemini/*" ".config/opencode/*" ".copilot/*" ".grok/*" ".config/AGENTS.md"
  ".config/alacritty/*" ".config/ghostty/*" ".config/kitty/*" ".config/foot/*" ".config/starship.toml"
  ".config/nvim/*" ".config/tmux/*" ".tmux.conf" ".config/waybar/*" ".config/walker/*" ".config/elephant/*"
  ".local/share/omarchy-backup/repo-sources/*" ".config/mise/*" ".mozilla/native-messaging-hosts/*"
  "*/NativeMessagingHosts/*" ".config/omarchy-backup/*"
)

ob_review_is_data_only() {  # <relative path>
  local base="${1##*/}" ext
  [[ "$base" == *.* ]] || return 1
  ext="${base##*.}"; ext="${ext,,}"
  [[ "$ext" =~ ^($OB_REVIEW_DATA_ONLY_EXT)$ ]]
}

ob_review_is_sensitive() {  # <relative path>
  local g
  for g in "${OB_REVIEW_SENSITIVE_GLOBS[@]}"; do
    # shellcheck disable=SC2254
    case "$1" in $g) return 0 ;; esac
  done
  return 1
}

ob_review_excerpt() {  # <file> <lines>
  local f="$1" n="$2" size
  size="$(stat -c %s -- "$f" 2>/dev/null || echo 0)"
  if [ "$size" -eq 0 ]; then echo "        (empty)"; return; fi
  if ! grep -Iq . -- "$f" 2>/dev/null; then echo "        (binary, $size bytes)"; return; fi
  echo "        ($size bytes)"
  head -n "$n" -- "$f" | cut -c1-200 | sed 's/^/        | /'
  [ "$(wc -l < "$f")" -gt "$n" ] && echo "        | ... (more in the file)"
  return 0
}

# ob_restore_review <unpacked tree> <manifest json> -> 0 continue, 1 stop.
ob_restore_review() {
  local tree="$1" manifest="$2" f rel kind new=0 changed=0 same=0 data=0 lines difflines
  local report details groups sname
  sname="$(printf '%s' "$manifest" | jq -r '.name // "snapshot"')"
  sname="${sname//[^A-Za-z0-9._-]/_}"
  report="$OB_DATA_DIR/restore-review-$sname-$(date '+%Y%m%d-%H%M%S').txt"
  details="$(mktemp)"; groups="$(mktemp)"
  ( umask 077; : > "$report" )
  while IFS= read -r -d '' f; do
    rel="${f#"$tree"/}"
    if [ -L "$f" ]; then
      [ "$(readlink -- "$f")" = "$(readlink -- "$HOME/$rel" 2>/dev/null)" ] && { same=$((same + 1)); continue; }
    elif [ -f "$HOME/$rel" ] && [ ! -L "$HOME/$rel" ] && cmp -s -- "$f" "$HOME/$rel"; then
      same=$((same + 1)); continue
    fi
    if [ -e "$HOME/$rel" ] || [ -L "$HOME/$rel" ]; then kind=CHANGED; changed=$((changed + 1)); else kind=NEW; new=$((new + 1)); fi
    printf '%s\t%s\n' "$(dirname -- "$rel")" "$kind" >> "$groups"
    if ob_review_is_data_only "$rel"; then data=$((data + 1)); continue; fi
    if ob_review_is_sensitive "$rel"; then lines=200; difflines=200; else lines=8; difflines=40; fi
    {
      if [ -L "$f" ]; then
        echo "    $kind  ~/$rel -> $(readlink -- "$f")"
      elif [ "$rel" = ".config/omarchy-backup/config.conf" ]; then
        echo "    $kind  ~/$rel  (sourced as code; written as config.conf.restored, NOT activated)"
        diff -u --label "current" --label "snapshot" -- "$HOME/$rel" "$f" 2>/dev/null | sed 's/^/        /'
      elif [ "$kind" = CHANGED ] && [ -f "$HOME/$rel" ] && grep -Iq . -- "$f" 2>/dev/null; then
        echo "    $kind  ~/$rel"
        diff -u --label "current" --label "snapshot" -- "$HOME/$rel" "$f" 2>/dev/null | head -n "$difflines" | sed 's/^/        /'
      else
        echo "    $kind  ~/$rel"
        ob_review_excerpt "$f" "$lines"
      fi
    } >> "$details"
  done < <(find "$tree" \( -type f -o -type l \) -print0 | sort -z)

  local pkgs units net
  pkgs="$(ob_restore_missing_packages "$manifest" | sed 's/^native /    pacman   /; s/^aur /    AUR      /; s/^invalid \(.*\)/    IGNORED  invalid package name: \1/')"
  units="$(printf '%s' "$manifest" | jq -r '.systemd_user_units[]? | select(.enabled=="enabled" or .active=="active") | [.name, .enabled, .active] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r u e a; do
        if ob_restore_unit_name_valid "$u"; then
          printf '    unit     %s%s%s\n' "$u" "$([ "$e" = enabled ] && echo " (enable)")" "$([ "$a" = active ] && echo " (start)")"
        else
          printf '    IGNORED  invalid unit name: %q\n' "$u"
        fi
      done)"
  net="$(printf '%s' "$manifest" | jq -r '
    (.plugins.git_managed[]? | "    plugin   \(.id // "?") from \(.remote // "?") @ \((.commit // "")[0:12])"),
    (.repos[]? | select((.missing // false) != true and (.remote // "") != "") | "    repo     ~/\(.path) from \(.remote)")' 2>/dev/null)"

  {
    echo "== Review: what this restore would write, install and run =="
    if [ $((new + changed)) -eq 0 ]; then
      echo "  No file would be added or changed ($same identical)."
    else
      echo "  $new new and $changed changed file(s), $same identical; per folder:"
      awk -F'\t' '{n[$1]++; if ($2=="NEW") a[$1]++; else c[$1]++}
        END {for (d in n) printf "    %4d new %4d changed  ~/%s\n", a[d]+0, c[d]+0, d}' "$groups" | sort -k5
      [ "$data" -gt 0 ] && echo "  ($data of them are images/fonts, not shown in detail.)"
      echo "  In detail (code and configuration in full up to 200 lines, other files as excerpts):"
      cat -- "$details"
    fi
    [ -n "$pkgs" ] && { echo "  Packages to install (AUR ones are built from source):"; printf '%s\n' "$pkgs"; }
    [ -n "$units" ] && { echo "  systemd user units to enable/start:"; printf '%s\n' "$units"; }
    [ -n "$net" ] && { echo "  Code fetched from the network:"; printf '%s\n' "$net"; }
    true
  } >> "$report"
  rm -f -- "$details" "$groups"

  echo
  if [ -t 1 ] && [ "$(wc -l < "$report")" -gt 60 ]; then
    ${PAGER:-less -R} "$report" </dev/tty >/dev/tty 2>&1 || cat -- "$report"
  else
    cat -- "$report"
  fi
  echo
  echo "  Summary: $new new, $changed changed, $same identical file(s)$([ -n "$pkgs" ] && echo ", packages to install")$([ -n "$units" ] && echo ", units to enable/start")$([ -n "$net" ] && echo ", code from the network")."
  echo "  Full review: $report"
  echo
  [ $((new + changed)) -eq 0 ] && [ -z "$pkgs" ] && [ -z "$units" ] && [ -z "$net" ] && return 0
  [ "${OB_DRY_RUN:-false}" = true ] && return 0
  [ "${OB_RESTORE_YES:-false}" = true ] && { ob_info "Review accepted via --yes."; return 0; }
  ob_confirm "Write, install and run all of the above?" && return 0
  ob_err "Stopped before writing anything. Review the list above; re-run with --yes to accept it non-interactively."
  return 1
}
