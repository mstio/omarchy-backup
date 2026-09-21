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

ob_restore_plugins() {
  local manifest="$1"
  local plugins_dir="$HOME/.config/omarchy/plugins"
  mkdir -p "$plugins_dir"

  local id remote commit dirty diff
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    remote="$(echo "$manifest" | jq -r --arg id "$id" '.plugins.git_managed[] | select(.id==$id) | .remote')"
    commit="$(echo "$manifest" | jq -r --arg id "$id" '.plugins.git_managed[] | select(.id==$id) | .commit')"
    dirty="$(echo "$manifest" | jq -r --arg id "$id" '.plugins.git_managed[] | select(.id==$id) | .dirty')"
    diff="$(echo "$manifest" | jq -r --arg id "$id" '.plugins.git_managed[] | select(.id==$id) | .diff')"

    if [ -z "$remote" ]; then
      ob_restore_note "Plugin '$id' had no recorded git remote; install/clone it manually."
      continue
    fi
    if [ -d "$plugins_dir/$id/.git" ]; then
      echo "  Plugin '$id' already present, leaving as-is."
    elif ob_require_tool omarchy; then
      ob_restore_run_step "install plugin '$id' from $remote" \
        omarchy plugin add "$remote" --yes
      if [ "$OB_DRY_RUN" != "true" ] && [ -d "$plugins_dir/$id/.git" ] && [ -n "$commit" ]; then
        git -C "$plugins_dir/$id" checkout --quiet "$commit" 2>/dev/null \
          || ob_restore_note "Plugin '$id': could not check out recorded commit $commit (upstream may have rewritten history)."
        if [ "$dirty" = "true" ] && [ -n "$diff" ]; then
          if echo "$diff" | git -C "$plugins_dir/$id" apply --check - 2>/dev/null; then
            echo "$diff" | git -C "$plugins_dir/$id" apply -
            echo "  Reapplied local uncommitted changes to '$id'."
          else
            ob_restore_note "Plugin '$id' had local uncommitted changes that no longer apply cleanly; diff saved to $OB_DATA_DIR/restore-$id.diff for manual review."
            echo "$diff" > "$OB_DATA_DIR/restore-$id.diff"
          fi
        fi
      fi
    else
      ob_restore_note "omarchy CLI not found; clone plugin '$id' manually from $remote"
    fi
  done < <(echo "$manifest" | jq -r '.plugins.git_managed[].id, .plugins.local_managed[]' | sort -u)

  local enable_ids disable_ids
  enable_ids="$(echo "$manifest" | jq -r '.plugins.enabled[]' 2>/dev/null)"
  if [ -n "$enable_ids" ] && ob_require_tool omarchy; then
    while IFS= read -r id; do
      [ -z "$id" ] && continue
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
