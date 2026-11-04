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

  ob_sweep_stale_staging
  local dir="$OB_SNAPSHOTS_DIR/$name"
  if [ ! -f "$dir/manifest.json" ] && { [ -e "$dir" ] || [ -L "$dir" ]; }; then
    # An interrupted earlier attempt: keep it, but out of the way.
    local stale; stale="$dir.stale-$(date '+%Y%m%d-%H%M%S')"
    mv -- "$dir" "$stale" || ob_die "Local '$name' is incomplete (no manifest.json) and could not be moved aside."
    ob_warn "Local '$name' had no manifest.json (interrupted download?); moved aside to $stale."
  fi
  if [ ! -f "$dir/manifest.json" ]; then
    if ob_remote_configured; then
      ob_info "Snapshot '$name' not found locally; trying remote..."
      ob_remote_pull "$name" "$dir"
    else
      ob_die "No such snapshot: $name (and no remote configured)"
    fi
  fi

  # Never trust the input: the signature (trust anchor from this machine's
  # config or the command line, never from the snapshot) comes first.
  ob_sig_gate "$dir" "the restore" || exit 1

  local manifest; manifest="$(jq . "$dir/manifest.json")" || ob_die "manifest.json of '$name' is not valid JSON."
  ob_info "Restoring snapshot '$name' (created $(echo "$manifest" | jq -r .created_at), Omarchy $(echo "$manifest" | jq -r .omarchy_version))"

  # --- integrity: payload checksum, on a private copy ---
  # The payload is copied once into a 0700 folder under the data dir, checked
  # there and unpacked there (size-capped); review and restore both use that
  # one tree, so nothing can swap the archive between check and use.
  OB_RESTORE_STAGE="$(mktemp -d "$OB_DATA_DIR/.restore-stage.XXXXXX")" || ob_die "Could not create a staging folder."
  chmod 700 -- "$OB_RESTORE_STAGE"
  trap 'rm -rf -- "${OB_RESTORE_STAGE:?}"' EXIT
  cp -- "$dir/payload.tar.zst" "$OB_RESTORE_STAGE/payload.tar.zst" || ob_die "Could not copy the payload."
  local stored_sha actual_sha
  stored_sha="$(echo "$manifest" | jq -r .payload.sha256)"
  actual_sha="$(sha256sum -- "$OB_RESTORE_STAGE/payload.tar.zst" | awk '{print $1}')"
  if [ "$stored_sha" != "$actual_sha" ]; then
    ob_die "Payload checksum mismatch for '$name' -- archive is corrupt, aborting restore."
  fi
  ob_info "Payload integrity OK."
  ob_restore_unpack "$OB_RESTORE_STAGE" "$manifest" || exit 1
  OB_RESTORE_TREE="$OB_RESTORE_STAGE/tree"

  # Before anything is written: everything new or changed, in full.
  ob_restore_review "$OB_RESTORE_TREE" "$manifest" || exit 1

  local current_omarchy; current_omarchy="$(ob_inv_omarchy_version)"
  local snap_omarchy; snap_omarchy="$(echo "$manifest" | jq -r .omarchy_version)"
  if [ "$current_omarchy" != "$snap_omarchy" ]; then
    ob_warn "Snapshot was taken on Omarchy $snap_omarchy, this system runs $current_omarchy. Proceeding, but review \`omarchy-backup doctor\` afterwards."
  fi

  echo
  echo "== 1/8 Packages =="
  ob_restore_packages "$manifest"

  echo
  echo "== 2/8 Omarchy plugins =="
  ob_restore_plugins "$manifest"

  echo
  echo "== 3/8 Scripts, dotfiles, themes, agent config, machine memory =="
  ob_restore_payload "$OB_RESTORE_TREE"
  # Tools pinned via mise (agent CLIs, gh, node) are listed, not embedded.
  if [ -f "$OB_RESTORE_TREE/.config/mise/config.toml" ]; then
    ob_restore_note "Install the tools pinned in ~/.config/mise/config.toml: mise install"
  fi

  echo
  echo "== 4/8 Own git checkouts (paths.conf: repo) =="
  ob_restore_repos "$manifest" "$dir"

  echo
  echo "== 5/8 systemd user units =="
  ob_restore_systemd "$manifest"

  echo
  echo "== 6/8 Symlink structure =="
  echo "  (recreated as part of the payload extraction above; nothing further to do)"

  echo
  echo "== 7/8 Integrity check =="
  if [ "$OB_DRY_RUN" = "true" ]; then
    echo "  [dry-run] skipped (nothing was written)"
  else
    ob_restore_verify "$dir"
  fi

  echo
  echo "== 8/8 Remaining manual steps =="
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
  local manifest="$1" line
  local -a native=() aur=()
  while IFS= read -r line; do
    case "$line" in
      "native "*) native+=("${line#native }") ;;
      "aur "*) aur+=("${line#aur }") ;;
      "invalid "*) ob_restore_note "Ignored a package name from the snapshot that is not a valid package name: $(printf '%q' "${line#invalid }")" ;;
    esac
  done < <(ob_restore_missing_packages "$manifest")

  if [ "${#native[@]}" -gt 0 ]; then
    ob_restore_run_step "install missing native packages" \
      sudo pacman -S --needed --noconfirm -- "${native[@]}"
  else
    echo "  No missing native packages."
  fi

  if [ "${#aur[@]}" -gt 0 ]; then
    if ob_require_tool yay; then
      ob_restore_run_step "install missing AUR packages via yay" \
        yay -S --needed --noconfirm "${aur[@]}"
    elif ob_require_tool paru; then
      ob_restore_run_step "install missing AUR packages via paru" \
        paru -S --needed --noconfirm "${aur[@]}"
    else
      ob_restore_note "No AUR helper (yay/paru) found -- install these AUR packages manually: ${aur[*]}"
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

ob_restore_repo_path_valid() {
  # Relative to $HOME, no absolute path, no `..` component, no control chars.
  local rel="${1:-}"
  [ -n "$rel" ] && [ "${#rel}" -le 1024 ] || return 1
  [[ "$rel" != /* && "$rel" != -* ]] || return 1
  [[ "$rel" != *$'\n'* && "$rel" != *$'\r'* ]] || return 1
  [[ "/$rel/" != *"/../"* && "/$rel/" != *"/./"* ]]
}

ob_restore_repo_from_archive() {
  # ob_restore_repo_from_archive <rel> <archive-rel> <snapshot-dir> <remote> <branch> <reason>
  # Fallback without git access: unpack the snapshot's embedded copy of the
  # tracked files (uncommitted edits included, no history). The archive is
  # read from the restored payload, or straight from the snapshot in a dry run.
  local rel="$1" arc="$2" sdir="$3" remote="$4" branch="$5" reason="$6" target="$HOME/$1"
  if [ -z "$arc" ] || [[ "$arc" != .local/share/omarchy-backup/repo-sources/*.tar ]] \
      || ! ob_restore_repo_path_valid "$arc"; then
    ob_restore_note "Repo ~/$rel: $reason, and the snapshot has no embedded copy -- clone ${remote:-it} manually."
    return 0
  fi
  if [ "$OB_DRY_RUN" = "true" ]; then
    echo "  [dry-run] $reason -> unpack the snapshot's embedded copy into ~/$rel (no git history)"
    return 0
  fi
  if [ ! -f "$HOME/$arc" ]; then
    ob_restore_note "Repo ~/$rel: $reason, and the embedded copy ~/$arc is missing -- clone ${remote:-it} manually."
    return 0
  fi
  local stage; stage="$(dirname -- "$target")/.$(basename -- "$target").restore.tmp.$$"
  rm -rf -- "$stage"; mkdir -p -- "$stage"
  # GNU tar refuses absolute and `..` member names by default.
  if ! tar -x -f "$HOME/$arc" -C "$stage" --no-same-owner 2>/dev/null; then
    rm -rf -- "$stage"
    ob_restore_note "Repo ~/$rel: $reason, and the embedded copy could not be unpacked -- clone ${remote:-it} manually."
    return 0
  fi
  mv -- "$stage" "$target"
  echo "  -> ~/$rel restored from the snapshot's embedded copy ($reason)"
  if [ -n "$remote" ]; then
    ob_restore_note "Repo ~/$rel came from the snapshot's embedded copy without git history. To reconnect it later: cd ~/$rel && git init -q && git remote add origin $remote && git fetch origin && git reset origin/${branch:-HEAD}"
  fi
}

ob_restore_repo_from_bundle() {
  # ob_restore_repo_from_bundle <rel> <bundle-rel> <snapshot-dir> <remote> <branch> <commit> <dirty> <diff> <reason>
  # Rebuilds the checkout from the snapshot's history bundle: every branch,
  # tag and remote-tracking ref as it was, origin set to the recorded remote
  # (if any), the recorded branch/commit checked out and tracked uncommitted
  # edits reapplied. Returns 1 (caller falls back to the file-only copy) if
  # there is no usable bundle.
  local rel="$1" bun="$2" sdir="$3" remote="$4" branch="$5" commit="$6" dirty="$7" diff="$8" reason="$9"
  local target="$HOME/$rel" src stage
  [ -n "$bun" ] && [[ "$bun" == .local/share/omarchy-backup/repo-sources/*.bundle ]] \
    && ob_restore_repo_path_valid "$bun" || return 1
  # $bkind comes from ob_restore_repos. A delta bundle needs the commits the
  # remote has as its base; without the remote it cannot rebuild anything.
  if [ "${bkind:-full}" != full ]; then
    ob_restore_note "Repo ~/$rel: the snapshot only holds the commits its remote lacked (no \`full\` on its repo line); without that remote they cannot rebuild the history, so only the files come back. \`repo ~/$rel full\` avoids this."
    return 1
  fi
  ob_require_tool git || return 1
  if [ "$OB_DRY_RUN" = "true" ]; then
    # Step 3 did not write the payload; the bundle is still inside it.
    if [ -n "${OB_RESTORE_TREE:-}" ] && [ -f "$OB_RESTORE_TREE/$bun" ]; then
      echo "  [dry-run] $reason -> rebuild ~/$rel from the snapshot's history bundle (all branches and tags)"
      return 0
    fi
    return 1
  fi
  src="$HOME/$bun"
  [ -f "$src" ] || return 1
  stage="$(dirname -- "$target")/.$(basename -- "$target").restore.tmp.$$"
  rm -rf -- "$stage"; mkdir -p -- "$(dirname -- "$target")"
  if ! git init -q -- "$stage" >/dev/null 2>&1 \
      || ! git -C "$stage" bundle verify -q -- "$src" >/dev/null 2>&1 \
      || ! ob_restore_fetch_bundle "$stage" "$src" "$rel" --update-head-ok 'refs/*:refs/*'; then
    rm -rf -- "$stage"
    ob_restore_note "Repo ~/$rel: the snapshot's history bundle could not be read; falling back to the file-only copy."
    return 1
  fi
  if [ -n "$remote" ] && ob_restore_plugin_remote_valid "$remote"; then
    git -C "$stage" remote add origin "$remote" 2>/dev/null
  fi
  if [ -n "$branch" ] && git -C "$stage" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$stage" checkout -q -f "$branch" 2>/dev/null
    git -C "$stage" show-ref --verify --quiet "refs/remotes/origin/$branch" \
      && git -C "$stage" branch -q --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1
  fi
  if ob_restore_plugin_commit_valid "$commit" && git -C "$stage" cat-file -e "${commit}^{commit}" 2>/dev/null \
      && [ "$(git -C "$stage" rev-parse HEAD 2>/dev/null)" != "$commit" ]; then
    git -C "$stage" -c advice.detachedHead=false checkout -q -f --detach "$commit"
    ob_restore_note "Repo ~/$rel: snapshot commit ${commit:0:12} was not on a branch; checked out detached -- review."
  fi
  if ! git -C "$stage" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    rm -rf -- "$stage"
    ob_restore_note "Repo ~/$rel: the snapshot's history bundle has no usable checkout; falling back to the file-only copy."
    return 1
  fi
  # The fetch may have pointed the unborn branch at a commit without
  # populating index and working tree.
  git -C "$stage" reset -q --hard HEAD >/dev/null 2>&1
  mv -- "$stage" "$target"
  if [ "$dirty" = "true" ] && [ -n "$diff" ]; then
    if echo "$diff" | git -C "$target" apply --check - 2>/dev/null; then
      echo "$diff" | git -C "$target" apply -
      echo "  Reapplied uncommitted changes to ~/$rel."
    else
      local diff_file="$OB_DATA_DIR/restore-repo-$(echo "$rel" | tr '/' '_').diff"
      echo "$diff" > "$diff_file"
      ob_restore_note "Repo ~/$rel had uncommitted changes that no longer apply cleanly; saved to $diff_file."
    fi
  fi
  echo "  -> ~/$rel restored from the snapshot's history bundle ($reason) at $(git -C "$target" rev-parse --short HEAD 2>/dev/null)"
  [ -n "$remote" ] || echo "     (no remote was recorded; history and tags are complete, consider adding one)"
  return 0
}

ob_restore_fetch_bundle() {
  # ob_restore_fetch_bundle <stage> <bundle> <rel> <fetch option> <refspec...>
  # With object checks first; a history git fsck objects to (bad dates or
  # e-mails from old tools, common in old forks) is still imported, with a
  # note, instead of being dropped.
  local stage="$1" src="$2" rel="$3" opt="$4"; shift 4
  git -C "$stage" -c transfer.fsckObjects=true fetch -q "$opt" -- "$src" "$@" >/dev/null 2>&1 && return 0
  if git -C "$stage" fetch -q "$opt" -- "$src" "$@" >/dev/null 2>&1; then
    ob_restore_note "Repo ~/$rel: the history bundle contains objects \`git fsck\` rejects; imported without that check -- run \`git fsck\` there."
    return 0
  fi
  return 1
}

ob_restore_merge_bundle() {
  # ob_restore_merge_bundle <stage> <bundle-rel> <rel>
  # After a successful clone: add what only the snapshot's history bundle
  # has -- commits, local branches and tags the remote never received.
  # Never moves a ref the remote already has further than the snapshot;
  # the checked-out branch itself is handled by the caller.
  local stage="$1" bun="$2" rel="$3" src cur r name snap
  [ -n "$bun" ] && [[ "$bun" == .local/share/omarchy-backup/repo-sources/*.bundle ]] \
    && ob_restore_repo_path_valid "$bun" || return 0
  src="$HOME/$bun"
  [ -f "$src" ] || return 0
  git -C "$stage" bundle verify -q -- "$src" >/dev/null 2>&1 || {
    ob_restore_note "Repo ~/$rel: the snapshot's history bundle could not be read (or the commits it builds on are no longer at the remote); unpushed work from it was not merged."
    return 0
  }
  # Non-forced: an existing tag with different content is kept (rejected).
  # (A rejected tag makes fetch fail although everything else arrived.)
  ob_restore_fetch_bundle "$stage" "$src" "$rel" --no-tags \
    'refs/heads/*:refs/ob-snapshot/heads/*' 'refs/tags/*:refs/tags/*' || true
  cur="$(git -C "$stage" symbolic-ref --quiet --short HEAD 2>/dev/null)"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    name="${r#refs/ob-snapshot/heads/}"
    [ "$name" = "$cur" ] && continue
    git -C "$stage" show-ref --verify --quiet "refs/heads/$name" && continue
    snap="$(git -C "$stage" rev-parse "$r")"
    if git -C "$stage" show-ref --verify --quiet "refs/remotes/origin/$name" \
        && git -C "$stage" merge-base --is-ancestor "$snap" "refs/remotes/origin/$name" 2>/dev/null; then
      continue  # the remote already has all of it
    fi
    git -C "$stage" branch -q -- "$name" "$snap" 2>/dev/null || continue
    if git -C "$stage" show-ref --verify --quiet "refs/remotes/origin/$name"; then
      git -C "$stage" branch -q --set-upstream-to="origin/$name" "$name" >/dev/null 2>&1
      ob_restore_note "Repo ~/$rel: branch '$name' restored from the snapshot; it has commits origin/$name lacks -- review and push."
    else
      echo "  ~/$rel: restored unpublished branch '$name' from the snapshot's history bundle."
    fi
  done < <(git -C "$stage" for-each-ref --format='%(refname)' refs/ob-snapshot/heads/)
  git -C "$stage" for-each-ref --format='delete %(refname)' refs/ob-snapshot/ | git -C "$stage" update-ref --stdin 2>/dev/null
  return 0
}

ob_restore_local_refs() {
  # ob_restore_local_refs <stage> <rel>   (reads $lrefs from ob_restore_repos)
  # Local branches and tags the remote does not have but whose objects are
  # there (e.g. a lightweight tag on a pushed commit) -- a delta bundle
  # cannot carry such refs, the manifest's `local_refs` does.
  local stage="$1" rel="$2" ref sha name
  [ -n "${lrefs:-}" ] && [ "$lrefs" != "[]" ] || return 0
  while IFS=$'\t' read -r ref sha; do
    [[ "$sha" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || continue
    case "$ref" in refs/heads/*|refs/tags/*) ;; *) continue ;; esac
    git check-ref-format "$ref" 2>/dev/null || continue
    git -C "$stage" show-ref --verify --quiet "$ref" && continue
    case "$ref" in
      refs/heads/*)
        name="${ref#refs/heads/}"
        # Already contained in the remote's branch: nothing local to restore.
        git -C "$stage" show-ref --verify --quiet "refs/remotes/origin/$name" \
          && git -C "$stage" merge-base --is-ancestor "$sha" "refs/remotes/origin/$name" 2>/dev/null \
          && continue ;;
    esac
    if ! git -C "$stage" cat-file -e "$sha" 2>/dev/null; then
      ob_restore_note "Repo ~/$rel: ${ref#refs/} could not be restored (${sha:0:12} is neither at the remote nor in the snapshot)."
      continue
    fi
    git -C "$stage" update-ref "$ref" "$sha" "" 2>/dev/null || continue
    echo "  ~/$rel: restored local ${ref#refs/} from the snapshot."
  done < <(printf '%s' "$lrefs" | jq -r '.[]? | [.ref, .sha] | @tsv' 2>/dev/null)
}

# Snapshot fallback chain: history bundle first (needs git), then the
# file-only copy of the tracked files.
ob_restore_repo_from_snapshot() {
  # <rel> <archive-rel> <bundle-rel> <snapshot-dir> <remote> <branch> <commit> <dirty> <diff> <reason>
  ob_restore_repo_from_bundle "$1" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" && return 0
  ob_restore_repo_from_archive "$1" "$2" "$4" "$5" "$6" "${10}"
}

ob_restore_repos() {
  # Re-clones the user's own git checkouts (declared with `repo <path>`).
  # Unlike plugins, these are working repositories: the remote's branch tip
  # wins when it already contains the snapshot's commit (work pushed after
  # the snapshot is kept); otherwise the snapshot commit is checked out
  # detached. Existing directories are never touched. Without access to the
  # remote, or with OB_REPOS_FROM_SNAPSHOT=true, the snapshot's history
  # bundle is used instead, or (no bundle / no git) its file-only copy;
  # step 3 restored both with the payload.
  local manifest="$1" sdir="${2:-}" entries
  entries="$(echo "$manifest" | jq -c '.repos[]? | select(.missing != true)' 2>/dev/null)"
  if [ -z "$entries" ]; then
    echo "  No recorded git checkouts."
    return 0
  fi
  local e rel remote branch commit dirty diff untracked target stage tip
  while IFS= read -r e; do
    [ -z "$e" ] && continue
    rel="$(echo "$e" | jq -r '.path // ""')"
    remote="$(echo "$e" | jq -r '.remote // ""')"
    branch="$(echo "$e" | jq -r '.branch // ""')"
    commit="$(echo "$e" | jq -r '.commit // ""')"
    dirty="$(echo "$e" | jq -r '.dirty // false')"
    diff="$(echo "$e" | jq -r '.diff // ""')"
    untracked="$(echo "$e" | jq -r '.untracked // 0')"
    local arc; arc="$(echo "$e" | jq -r '.source_archive // ""')"
    local bun; bun="$(echo "$e" | jq -r '.history_bundle // ""')"
    # Read by ob_restore_repo_from_bundle / ob_restore_local_refs (dynamic
    # scope). Snapshots before the delta mode only had full bundles.
    local bkind; bkind="$(echo "$e" | jq -r '.history_bundle_kind // ""')"
    case "$bkind" in full|delta) ;; *) bkind=full ;; esac
    local lrefs; lrefs="$(echo "$e" | jq -c '.local_refs // []')"
    if ! ob_restore_repo_path_valid "$rel"; then
      ob_restore_note "Snapshot lists a repo with an unsafe path ($(printf '%q' "$rel")); ignored -- review the manifest manually."
      continue
    fi
    target="$HOME/$rel"
    local remote_ok=true
    ob_restore_plugin_remote_valid "$remote" || remote_ok=false
    if [ -n "$branch" ] && ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
      branch=""
    fi
    [ "$untracked" -gt 0 ] 2>/dev/null \
      && ob_restore_note "Repo ~/$rel had $untracked untracked file(s) at snapshot time; those were never backed up."
    if [ -d "$target/.git" ]; then
      if [ "$(git -C "$target" remote get-url origin 2>/dev/null)" = "$remote" ]; then
        echo "  ~/$rel already present, leaving as-is."
      else
        ob_restore_note "Repo ~/$rel exists with a different origin than recorded ($remote); left untouched."
      fi
      continue
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then
      ob_restore_note "~/$rel exists but is not a git checkout; not touched -- clone $remote there manually."
      continue
    fi
    if [ "$remote_ok" != true ]; then
      ob_restore_repo_from_snapshot "$rel" "$arc" "$bun" "$sdir" "" "$branch" "$commit" "$dirty" "$diff" "no usable git remote recorded"
      continue
    fi
    if [ "${OB_REPOS_FROM_SNAPSHOT:-false}" = "true" ]; then
      ob_restore_repo_from_snapshot "$rel" "$arc" "$bun" "$sdir" "$remote" "$branch" "$commit" "$dirty" "$diff" "--repos-from-snapshot"
      continue
    fi
    if ! ob_require_tool git; then
      ob_restore_repo_from_snapshot "$rel" "$arc" "$bun" "$sdir" "$remote" "$branch" "$commit" "$dirty" "$diff" "git is not installed"
      continue
    fi
    if [ "$OB_DRY_RUN" = "true" ]; then
      echo "  [dry-run] clone $remote -> ~/$rel (${branch:-default branch}, snapshot commit ${commit:0:12}); falls back to the snapshot's history bundle / embedded copy if cloning fails"
      continue
    fi

    echo "  -> clone $remote -> ~/$rel"
    mkdir -p -- "$(dirname -- "$target")"
    stage="$(dirname -- "$target")/.$(basename -- "$target").restore.tmp.$$"
    rm -rf -- "$stage"
    if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}" \
        timeout --signal=TERM --kill-after=5s "${OB_REMOTE_OPERATION_TIMEOUT_SECONDS:-900}s" \
        git clone --quiet -- "$remote" "$stage" >/dev/null 2>&1; then
      rm -rf -- "$stage"
      ob_warn "Could not clone $remote (private repo without \`gh auth login && gh auth setup-git\`? no network?)"
      ob_restore_repo_from_snapshot "$rel" "$arc" "$bun" "$sdir" "$remote" "$branch" "$commit" "$dirty" "$diff" "cloning failed"
      continue
    fi
    if [ -n "$branch" ] && [ "$(git -C "$stage" symbolic-ref --quiet --short HEAD 2>/dev/null)" != "$branch" ]; then
      git -C "$stage" checkout --quiet "$branch" 2>/dev/null || true
    fi
    ob_restore_merge_bundle "$stage" "$bun" "$rel"
    ob_restore_local_refs "$stage" "$rel"
    # The recorded branch may exist only now (unpublished, from the bundle).
    if [ -n "$branch" ] && [ "$(git -C "$stage" symbolic-ref --quiet --short HEAD 2>/dev/null)" != "$branch" ]; then
      if git -C "$stage" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$stage" checkout -q "$branch" 2>/dev/null
      else
        ob_restore_note "Repo ~/$rel: branch '$branch' not found at $remote; left on the default branch."
      fi
    fi
    if ob_restore_plugin_commit_valid "$commit" && git -C "$stage" cat-file -e "${commit}^{commit}" 2>/dev/null; then
      tip="$(git -C "$stage" rev-parse HEAD 2>/dev/null)"
      if [ "$tip" != "$commit" ] && [ -n "$branch" ] \
          && [ "$(git -C "$stage" symbolic-ref --quiet --short HEAD 2>/dev/null)" = "$branch" ] \
          && git -C "$stage" merge-base --is-ancestor HEAD "$commit" 2>/dev/null; then
        # Commits the remote never got, brought back by the history bundle.
        git -C "$stage" merge --quiet --ff-only "$commit" >/dev/null 2>&1
        echo "  ~/$rel: restored $(git -C "$stage" rev-list --count "$tip..$commit" 2>/dev/null) unpushed commit(s) on $branch from the snapshot's history bundle."
      elif [ "$tip" != "$commit" ] && ! git -C "$stage" merge-base --is-ancestor "$commit" HEAD 2>/dev/null; then
        git -C "$stage" -c advice.detachedHead=false checkout --quiet --detach "$commit"
        ob_restore_note "Repo ~/$rel: snapshot commit ${commit:0:12} is not on ${branch:-the default branch} at $remote; checked out detached -- review."
      elif [ "$tip" != "$commit" ]; then
        echo "  ~/$rel: remote is newer than the snapshot (${commit:0:12} -> ${tip:0:12}); keeping the remote state."
      fi
    else
      ob_restore_note "Repo ~/$rel: snapshot commit ${commit:0:12} is not at $remote (it was never pushed); checkout is at the remote's current state."
    fi
    mv -- "$stage" "$target"
    if [ "$dirty" = "true" ] && [ -n "$diff" ]; then
      if echo "$diff" | git -C "$target" apply --check - 2>/dev/null; then
        echo "$diff" | git -C "$target" apply -
        echo "  Reapplied uncommitted changes to ~/$rel."
      else
        local diff_file="$OB_DATA_DIR/restore-repo-$(echo "$rel" | tr '/' '_').diff"
        echo "$diff" > "$diff_file"
        ob_restore_note "Repo ~/$rel had uncommitted changes that no longer apply cleanly; saved to $diff_file."
      fi
    fi
    echo "  -> ~/$rel restored at $(git -C "$target" rev-parse --short HEAD 2>/dev/null)"
  done <<< "$entries"
}

# Unpacks <stage>/payload.tar.zst into <stage>/tree, refusing an archive
# that unpacks to more than 50x its compressed size (at least 64 MB, at most
# OB_RESTORE_MAX_UNPACKED_MB, default 1024). GNU tar drops absolute and `..`
# member names and delays symlinks, so nothing lands outside the tree.
ob_restore_unpack() {  # <stage> <manifest json>
  local stage="$1" manifest="$2" packed limit_mb limit size cap="${OB_RESTORE_MAX_UNPACKED_MB:-1024}"
  packed="$(stat -c %s -- "$stage/payload.tar.zst" 2>/dev/null || echo 0)"
  # 50x: text/JSON compressed with zstd -19 can exceed 20x (second opinion).
  limit_mb=$(( packed * 50 / 1024 / 1024 ))
  [ "$limit_mb" -ge 64 ] || limit_mb=64
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=1024
  [ "$limit_mb" -le "$cap" ] || limit_mb="$cap"
  limit=$(( limit_mb * 1024 * 1024 ))
  zstd -q -d -c "$stage/payload.tar.zst" 2>/dev/null | head -c "$((limit + 1))" > "$stage/payload.tar"
  size="$(stat -c %s -- "$stage/payload.tar" 2>/dev/null || echo 0)"
  if [ "$size" -gt "$limit" ]; then
    ob_err "The payload unpacks to more than ${limit_mb} MB; refusing (corrupt or hostile snapshot)."
    return 1
  fi
  mkdir -m 700 -- "$stage/tree" || return 1
  if ! tar -x -f "$stage/payload.tar" -C "$stage/tree" --no-same-owner --no-same-permissions 2>/dev/null; then
    ob_err "Could not unpack the payload."
    return 1
  fi
  rm -f -- "$stage/payload.tar"
}

# The tool's own config is bash-sourced and holds the trust anchor
# (signer, allowed signers, signing key, integrity remote): a restored copy
# never replaces the active one; it is written next to it for review.
OB_RESTORE_HELD_BACK=".config/omarchy-backup/config.conf"

ob_restore_payload() {
  local tree="$1"
  local f rel target
  while IFS= read -r -d '' f; do
    rel="${f#"$tree"/}"
    target="$HOME/$rel"
    if [ "$rel" = "$OB_RESTORE_HELD_BACK" ] && ! cmp -s -- "$f" "$target" 2>/dev/null; then
      if [ "$OB_DRY_RUN" = "true" ]; then
        echo "  [dry-run] would write $target.restored (active config.conf is kept)"
      else
        cp -a -- "$f" "$target.restored"
      fi
      ob_restore_note "The snapshot's ~/$rel was written as ~/$rel.restored and is NOT active (it is sourced as code and holds the trust settings). Compare: diff ~/$rel ~/$rel.restored -- adopt: mv ~/$rel.restored ~/$rel"
      continue
    fi
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
  done < <(find "$tree" \( -type f -o -type l \) -print0)
  echo "  Payload restored to \$HOME (existing differing files backed up alongside themselves)."
}

# Names from the (untrusted) manifest reach pacman/yay/systemctl only if
# they look like what they claim to be.
ob_restore_pkg_name_valid() { [[ "$1" =~ ^[a-z0-9@._+][a-z0-9@._+-]*$ ]]; }
ob_restore_unit_name_valid() {
  [[ "$1" =~ ^[A-Za-z0-9:_.@\\][A-Za-z0-9:_.@\\-]*\.(service|timer|socket|path|target|mount|slice)$ ]]
}

# Missing packages, validated: prints "native <name>" / "aur <name>" /
# "invalid <name>" lines.
ob_restore_missing_packages() {  # <manifest json>
  local have n kind
  have="$(pacman -Qq 2>/dev/null | sort -u)"
  for kind in native aur; do
    local key=pacman_explicit; [ "$kind" = aur ] && key=aur_foreign
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      if ! ob_restore_pkg_name_valid "$n"; then printf 'invalid %s\n' "$n"; continue; fi
      printf '%s\n' "$have" | grep -qxF -- "$n" || printf '%s %s\n' "$kind" "$n"
    done < <(printf '%s' "$1" | jq -r --arg k "$key" '.packages[$k][]? | strings' 2>/dev/null | sort -u)
  done
}

ob_restore_systemd() {
  local manifest="$1"
  local units; units="$(echo "$manifest" | jq -c '.systemd_user_units[]?' 2>/dev/null)"
  [ -z "$units" ] && { echo "  No recorded user units."; return 0; }

  if [ "$OB_DRY_RUN" != "true" ]; then
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  while IFS= read -r u; do
    local name enabled active
    name="$(echo "$u" | jq -r .name)"
    enabled="$(echo "$u" | jq -r .enabled)"
    active="$(echo "$u" | jq -r .active)"
    if ! ob_restore_unit_name_valid "$name"; then
      ob_restore_note "Ignored a unit name from the snapshot that is not a valid unit name: $(printf '%q' "$name")"
      continue
    fi
    if [ "$enabled" = "enabled" ]; then
      ob_restore_run_step "enable $name" systemctl --user enable -- "$name"
    fi
    if [ "$active" = "active" ]; then
      ob_restore_run_step "start $name" systemctl --user start -- "$name"
    fi
  done <<< "$units"
}

ob_restore_verify() {
  local dir="$1"
  local bad=0 path expected actual rel
  while IFS=$'\t' read -r hash rel; do
    [ -z "$rel" ] && continue
    case "$hash" in
      symlink:*) continue ;;
    esac
    [ "$rel" = "$OB_RESTORE_HELD_BACK" ] && continue  # written as .restored
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
