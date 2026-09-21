#!/bin/bash
# Staged restore: fresh Omarchy install -> functionally-the-same personal
# workspace. Every destructive step is dry-runnable via OB_DRY_RUN=true, and
# any existing file a restore would change is backed up next to itself
# first (never silently overwritten) -- consistent with this machine's own
# `<file>.bak.<timestamp>` convention.

OB_MANUAL_STEPS=()

ob_restore_note() { OB_MANUAL_STEPS+=("$1"); }

ob_restore_run_step() {
  # ob_restore_run_step "description" -- cmd args...
  # Never aborts the overall restore: a failed step is recorded as a manual
  # follow-up instead, so one bad step doesn't hide the rest of the plan.
  local desc="$1"; shift
  if [ "$OB_DRY_RUN" = "true" ]; then
    echo "  [dry-run] $desc"
    echo "            \$ $*"
    return 0
  fi
  echo "  -> $desc"
  if "$@"; then
    return 0
  fi
  ob_warn "Step failed: $desc"
  ob_restore_note "Failed automatically, do manually: $desc"
  return 0
}

ob_restore_backup_existing() {
  # If $1 exists and differs from what we're about to write, move it aside.
  local target="$1"
  [ -e "$target" ] || [ -L "$target" ] || return 0
  local bak="${target}.bak.$(date '+%Y%m%d-%H%M%S')"
  if [ "$OB_DRY_RUN" = "true" ]; then
    echo "  [dry-run] would back up existing $target -> $bak"
  else
    mkdir -p -- "$(dirname -- "$bak")"
    cp -a -- "$target" "$bak"
  fi
}

ob_restore_run() {
  local name="$1"
  ob_require_snapshot_name "$name"
  ob_ensure_dirs
  ob_load_config
  ob_read_path_rules
  ob_state_init_if_missing

  local dir="$OB_SNAPSHOTS_DIR/$name"
  if [ ! -f "$dir/manifest.json" ]; then
    if ob_remote_configured; then
      ob_info "Snapshot '$name' not found locally; trying remote..."
      ob_remote_pull "$name" "$dir"
    else
      ob_die "No such snapshot: $name (and no remote configured)"
    fi
  fi

  local manifest; manifest="$(jq . "$dir/manifest.json")"
  ob_info "Restoring snapshot '$name' (created $(echo "$manifest" | jq -r .created_at), Omarchy $(echo "$manifest" | jq -r .omarchy_version))"

  # --- integrity: payload checksum ---
  local stored_sha actual_sha
  stored_sha="$(echo "$manifest" | jq -r .payload.sha256)"
  actual_sha="$(sha256sum -- "$dir/payload.tar.zst" | awk '{print $1}')"
  if [ "$stored_sha" != "$actual_sha" ]; then
    ob_die "Payload checksum mismatch for '$name' -- archive is corrupt, aborting restore."
  fi
  ob_info "Payload integrity OK."

  local current_omarchy; current_omarchy="$(ob_inv_omarchy_version)"
  local snap_omarchy; snap_omarchy="$(echo "$manifest" | jq -r .omarchy_version)"
  if [ "$current_omarchy" != "$snap_omarchy" ]; then
    ob_warn "Snapshot was taken on Omarchy $snap_omarchy, this system runs $current_omarchy. Proceeding, but review \`omarchy-backup doctor\` afterwards."
  fi

  echo
  echo "== 1/7 Packages =="
  ob_restore_packages "$manifest"

  echo
  echo "== 2/7 Omarchy plugins =="
  ob_restore_plugins "$manifest"

  echo
  echo "== 3/7 Scripts, dotfiles, themes, agent config, machine memory =="
  ob_restore_payload "$dir"

  echo
  echo "== 4/7 systemd user units =="
  ob_restore_systemd "$manifest"

  echo
  echo "== 5/7 Symlink structure =="
  echo "  (recreated as part of the payload extraction above; nothing further to do)"

  echo
  echo "== 6/7 Integrity check =="
  if [ "$OB_DRY_RUN" = "true" ]; then
    echo "  [dry-run] skipped (nothing was written)"
  else
    ob_restore_verify "$dir"
  fi

  echo
  echo "== 7/7 Remaining manual steps =="
  ob_restore_report_manifest_gaps "$manifest"
  if [ "${#OB_MANUAL_STEPS[@]}" -eq 0 ]; then
    echo "  None recorded."
  else
    printf '  - %s\n' "${OB_MANUAL_STEPS[@]}"
  fi

  if [ "$OB_DRY_RUN" = "true" ]; then
    echo
    ob_info "Dry run complete. Re-run without --dry-run to apply."
  else
    echo
    ob_info "Restore of '$name' complete."
  fi
}

ob_restore_packages() {
  local manifest="$1"
  local want_native want_aur have
  want_native="$(echo "$manifest" | jq -r '.packages.pacman_explicit[]' 2>/dev/null)"
  want_aur="$(echo "$manifest" | jq -r '.packages.aur_foreign[]' 2>/dev/null)"
  have="$(pacman -Qq 2>/dev/null | sort -u)"

  local missing_native missing_aur
  missing_native="$(comm -23 <(echo "$want_native" | sort -u) <(echo "$have"))"
  missing_aur="$(comm -23 <(echo "$want_aur" | sort -u) <(echo "$have"))"

  if [ -n "$missing_native" ]; then
    # shellcheck disable=SC2086
    ob_restore_run_step "install missing native packages" \
      sudo pacman -S --needed --noconfirm $missing_native
  else
    echo "  No missing native packages."
  fi

  if [ -n "$missing_aur" ]; then
    if ob_require_tool yay; then
      # shellcheck disable=SC2086
      ob_restore_run_step "install missing AUR packages via yay" \
        yay -S --needed --noconfirm $missing_aur
    elif ob_require_tool paru; then
      # shellcheck disable=SC2086
      ob_restore_run_step "install missing AUR packages via paru" \
        paru -S --needed --noconfirm $missing_aur
    else
      ob_restore_note "No AUR helper (yay/paru) found -- install these AUR packages manually: $(echo "$missing_aur" | tr '\n' ' ')"
    fi
  else
    echo "  No missing AUR packages."
  fi

  local flat; flat="$(echo "$manifest" | jq -r '.packages.flatpak[]?' 2>/dev/null)"
  if [ -n "$flat" ]; then
    if ob_require_tool flatpak; then
      ob_restore_note "Flatpak apps recorded in snapshot -- verify/install: $(echo "$flat" | tr '\n' ' ')"
    else
      ob_restore_note "flatpak is not installed; snapshot recorded these Flatpak apps: $(echo "$flat" | tr '\n' ' ')"
    fi
  fi

  local appimgs; appimgs="$(echo "$manifest" | jq -r '.packages.appimages[]?.path' 2>/dev/null)"
  if [ -n "$appimgs" ]; then
    ob_restore_note "AppImages were detected but are not embedded (re-download manually): $(echo "$appimgs" | tr '\n' ' ')"
  fi
}

# Plugin pins recorded at snapshot time are enforced at restore time, not
# merely attempted. A third-party plugin's upstream can move, be force-pushed
# or be taken over between snapshot and restore, so a snapshot's own
# `{remote, commit}` is the only thing that says which code the user actually
# ran. The pinned commit is therefore fetched into a staging clone and checked
# out detached *before* `omarchy plugin add` copies it into the trusted plugin
# directory, and a plugin whose pinned commit cannot be found is neither
# installed nor enabled -- it becomes a manual step instead of silently
# falling back to whatever the remote's default branch points at today.
# This is not a judgement about the snapshot's trustworthiness (that remains
# the user's call); it is the tool keeping the promise its manifest makes.

ob_restore_plugin_id_valid() {
  # Same grammar `omarchy plugin validate` enforces for manifest ids.
  local id="${1:-}"
  [ "${#id}" -le 128 ] || return 1
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ "$id" != *".."* ]]
}

ob_restore_plugin_commit_valid() {
  [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]]
}

ob_restore_plugin_remote_valid() {
  # Mirrors omarchy-git-url-check: refuse anything git would read as an
  # option or as a remote-helper invocation (`ext::` runs a shell command),
  # allow only the transports git connects to itself, plus scp-style and
  # plain paths, which cannot reach a helper.
  local url="${1:-}" scheme t
  [ -n "$url" ] || return 1
  [ "${#url}" -le 2048 ] || return 1
  [[ "$url" != *$'\n'* && "$url" != *$'\r'* ]] || return 1
  [[ "$url" != -* ]] || return 1
  [[ ! "$url" =~ ^[A-Za-z0-9][A-Za-z0-9+.-]*:: ]] || return 1
  if [[ "$url" =~ ^([A-Za-z0-9][A-Za-z0-9+.-]*):// ]]; then
    scheme="${BASH_REMATCH[1]}"
    for t in ssh git git+ssh ssh+git http https ftp ftps file; do
      [ "$scheme" = "$t" ] && return 0
    done
    return 1
  fi
  return 0
}

ob_restore_plugins() {
  local manifest="$1"
  local plugins_dir="$HOME/.config/omarchy/plugins"
  mkdir -p "$plugins_dir"

  # Plugins that must NOT be enabled afterwards because their pinned code
  # could not be installed.
  local -a skip_enable=()

  local id remote commit dirty diff
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if ! ob_restore_plugin_id_valid "$id"; then
      ob_restore_note "Snapshot lists a plugin with an invalid id ($(printf '%q' "$id")); ignored -- review the manifest manually."
      continue
    fi
    remote="$(echo "$manifest" | jq -r --arg id "$id" '[.plugins.git_managed[]? | select(.id==$id) | .remote // ""][0] // ""')"
    commit="$(echo "$manifest" | jq -r --arg id "$id" '[.plugins.git_managed[]? | select(.id==$id) | .commit // ""][0] // ""')"
    dirty="$(echo "$manifest" | jq -r --arg id "$id" '[.plugins.git_managed[]? | select(.id==$id) | .dirty // false][0] // false')"
    diff="$(echo "$manifest" | jq -r --arg id "$id" '[.plugins.git_managed[]? | select(.id==$id) | .diff // ""][0] // ""')"

    if [ -z "$remote" ]; then
      # local_managed plugins arrive with the payload; git_managed ones
      # without a remote can only be reinstalled by hand.
      if echo "$manifest" | jq -e --arg id "$id" '.plugins.git_managed[]? | select(.id==$id)' >/dev/null 2>&1; then
        ob_restore_note "Plugin '$id' had no recorded git remote; install/clone it manually."
      fi
      continue
    fi
    if [ -d "$plugins_dir/$id/.git" ]; then
      echo "  Plugin '$id' already present, leaving as-is."
      continue
    fi
    if ! ob_restore_plugin_remote_valid "$remote"; then
      ob_restore_note "Plugin '$id': recorded remote is not a plain git URL ($(printf '%q' "$remote")); not installed or enabled -- review and install manually."
      skip_enable+=("$id")
      continue
    fi
    if ! ob_restore_plugin_commit_valid "$commit"; then
      ob_restore_note "Plugin '$id': snapshot has no full 40-character commit pin ($(printf '%q' "$commit")); not installed or enabled -- clone $remote and pick a revision manually."
      skip_enable+=("$id")
      continue
    fi
    if ! ob_require_tool omarchy; then
      ob_restore_note "omarchy CLI not found; clone plugin '$id' manually from $remote at commit $commit"
      continue
    fi
    if [ "$OB_DRY_RUN" = "true" ]; then
      echo "  [dry-run] install plugin '$id' from $remote pinned at $commit"
      echo "            \$ git clone -- $remote <staging> && git -C <staging> checkout --detach $commit"
      echo "            \$ omarchy plugin add <staging> --yes"
      continue
    fi

    echo "  -> install plugin '$id' from $remote pinned at ${commit:0:12}"
    local stage; stage="$plugins_dir/.restore.tmp.$id.$$"
    rm -rf -- "$stage"
    if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}" \
        timeout --signal=TERM --kill-after=5s "${OB_REMOTE_OPERATION_TIMEOUT_SECONDS:-900}s" \
        git clone --quiet -- "$remote" "$stage" >/dev/null 2>&1; then
      rm -rf -- "$stage"
      ob_warn "Step failed: clone plugin '$id' from $remote"
      ob_restore_note "Plugin '$id': could not clone $remote (credentials? private repo? network?); not installed or enabled -- install manually."
      skip_enable+=("$id")
      continue
    fi
    if ! git -C "$stage" cat-file -e "${commit}^{commit}" 2>/dev/null \
        || ! git -C "$stage" -c advice.detachedHead=false checkout --quiet --detach "$commit" 2>/dev/null; then
      rm -rf -- "$stage"
      ob_warn "Step failed: pinned commit $commit for plugin '$id' is not available at $remote"
      ob_restore_note "Plugin '$id': pinned commit $commit not found at $remote (history rewritten or remote changed); NOT installed or enabled -- review upstream and install manually."
      skip_enable+=("$id")
      continue
    fi
    local stage_id; stage_id="$(jq -r '.id // ""' "$stage/manifest.json" 2>/dev/null)"
    if [ "$stage_id" != "$id" ]; then
      rm -rf -- "$stage"
      ob_restore_note "Plugin '$id': repository at $remote (commit $commit) declares plugin id '$stage_id' instead; not installed or enabled -- review manually."
      skip_enable+=("$id")
      continue
    fi
    # `omarchy plugin add` accepts any git URL, including a local path, and
    # clones the staging checkout's detached HEAD -- i.e. exactly the pinned
    # commit -- while still running Omarchy's own manifest validation and
    # id-collision checks. Only afterwards is origin pointed back at the
    # real remote so future snapshots record the true upstream.
    if ! omarchy plugin add "$stage" --yes >/dev/null 2>&1 || [ ! -d "$plugins_dir/$id/.git" ]; then
      rm -rf -- "$stage"
      ob_warn "Step failed: omarchy plugin add for '$id'"
      ob_restore_note "Plugin '$id': 'omarchy plugin add' refused the pinned checkout (validation failed or id already taken); not installed or enabled -- install manually from $remote at $commit."
      skip_enable+=("$id")
      continue
    fi
    rm -rf -- "$stage"
    git -C "$plugins_dir/$id" remote set-url origin "$remote" 2>/dev/null || true
    if [ "$(git -C "$plugins_dir/$id" rev-parse HEAD 2>/dev/null)" != "$commit" ] \
        && ! git -C "$plugins_dir/$id" -c advice.detachedHead=false checkout --quiet --detach "$commit" 2>/dev/null; then
      ob_warn "Step failed: installed plugin '$id' is not at pinned commit $commit"
      ob_restore_note "Plugin '$id' was installed but is not at pinned commit $commit; NOT enabled -- inspect $plugins_dir/$id before enabling."
      skip_enable+=("$id")
      continue
    fi
    echo "  -> plugin '$id' installed at pinned commit ${commit:0:12}"
    if [ "$dirty" = "true" ] && [ -n "$diff" ]; then
      if echo "$diff" | git -C "$plugins_dir/$id" apply --check - 2>/dev/null; then
        echo "$diff" | git -C "$plugins_dir/$id" apply -
        echo "  Reapplied local uncommitted changes to '$id'."
      else
        ob_restore_note "Plugin '$id' had local uncommitted changes that no longer apply cleanly; diff saved to $OB_DATA_DIR/restore-$id.diff for manual review."
        echo "$diff" > "$OB_DATA_DIR/restore-$id.diff"
      fi
    fi
  done < <(echo "$manifest" | jq -r '(.plugins.git_managed[]?.id // empty), (.plugins.local_managed[]? // empty)' | sort -u)

  local enable_ids skip
  enable_ids="$(echo "$manifest" | jq -r '.plugins.enabled[]?' 2>/dev/null)"
  if [ -n "$enable_ids" ] && ob_require_tool omarchy; then
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      if ! ob_restore_plugin_id_valid "$id"; then
        ob_restore_note "Snapshot wants to enable a plugin with an invalid id ($(printf '%q' "$id")); ignored."
        continue
      fi
      skip=false
      local s
      for s in "${skip_enable[@]}"; do [ "$s" = "$id" ] && skip=true; done
      if [ "$skip" = true ]; then
        echo "  Not enabling '$id': its pinned code was not installed (see manual steps)."
        continue
      fi
      ob_restore_run_step "enable plugin '$id'" omarchy plugin enable "$id"
    done <<< "$enable_ids"
  fi
}

ob_restore_payload() {
  local dir="$1"
  local tmp; tmp="$(mktemp -d)"
  zstd -q -d -c "$dir/payload.tar.zst" | tar -x -C "$tmp"

  local f rel target
  while IFS= read -r -d '' f; do
    rel="${f#"$tmp"/}"
    target="$HOME/$rel"
    if [ -e "$target" ] || [ -L "$target" ]; then
      if [ -L "$f" ]; then
        [ "$(readlink -- "$f")" = "$(readlink -- "$target" 2>/dev/null)" ] && continue
      elif [ -f "$target" ] && cmp -s -- "$f" "$target"; then
        continue
      fi
      ob_restore_backup_existing "$target"
    fi
    if [ "$OB_DRY_RUN" = "true" ]; then
      echo "  [dry-run] would write $target"
    else
      mkdir -p -- "$(dirname -- "$target")"
      cp -a -- "$f" "$target"
    fi
  done < <(find "$tmp" \( -type f -o -type l \) -print0)

  rm -rf -- "$tmp"
  echo "  Payload restored to \$HOME (existing differing files backed up alongside themselves)."
}

ob_restore_systemd() {
  local manifest="$1"
  local units; units="$(echo "$manifest" | jq -c '.systemd_user_units[]?' 2>/dev/null)"
  [ -z "$units" ] && { echo "  No recorded user units."; return 0; }

  if [ "$OB_DRY_RUN" != "true" ]; then
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  echo "$units" | while IFS= read -r u; do
    local name enabled active
    name="$(echo "$u" | jq -r .name)"
    enabled="$(echo "$u" | jq -r .enabled)"
    active="$(echo "$u" | jq -r .active)"
    if [ "$enabled" = "enabled" ]; then
      ob_restore_run_step "enable $name" systemctl --user enable "$name"
    fi
    if [ "$active" = "active" ]; then
      ob_restore_run_step "start $name" systemctl --user start "$name"
    fi
  done
}

ob_restore_verify() {
  local dir="$1"
  local bad=0 path expected actual rel
  while IFS=$'\t' read -r hash rel; do
    [ -z "$rel" ] && continue
    case "$hash" in
      symlink:*) continue ;;
    esac
    path="$HOME/$rel"
    if [ ! -f "$path" ]; then
      ob_warn "Missing after restore: $path"
      bad=$((bad+1))
      continue
    fi
    actual="$(sha256sum -- "$path" | awk '{print $1}')"
    if [ "$actual" != "$hash" ]; then
      ob_warn "Checksum mismatch after restore (kept anyway, was likely intentionally modified since snapshot): $path"
      bad=$((bad+1))
    fi
  done < <(awk '{h=$1; $1=""; sub(/^ /,""); print h"\t"$0}' "$dir/checksums.sha256")
  if [ "$bad" -eq 0 ]; then
    echo "  All restored files verified against the snapshot's checksums."
  else
    echo "  $bad file(s) flagged above -- see warnings."
  fi
}

ob_restore_report_manifest_gaps() {
  local manifest="$1"
  local sl ss
  sl="$(echo "$manifest" | jq -r '.skipped_large_files[]?' 2>/dev/null)"
  ss="$(echo "$manifest" | jq -r '.skipped_secret_files[]?' 2>/dev/null)"
  [ -n "$sl" ] && ob_restore_note "Files skipped at snapshot time for being too large (never backed up, restore/reinstall manually): $(echo "$sl" | tr '\n' ';')"
  [ -n "$ss" ] && ob_restore_note "Files skipped at snapshot time as likely secrets (re-authenticate/re-enter manually): $(echo "$ss" | tr '\n' ';')"
  ob_restore_note "Secrets and logins (agent CLI credentials, SSH/GPG keys, browser passwords) are never included in a snapshot; re-authenticate each tool after restore."
}
