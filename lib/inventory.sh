#!/bin/bash
# Collects the reproducible "what is installed / enabled" inventory as JSON.
# All functions print JSON to stdout and are side-effect free.

ob_inv_omarchy_version() {
  pacman -Q omarchy 2>/dev/null | awk '{print $2}' || echo "unknown"
}

ob_inv_kernel_version() { uname -r; }

ob_inv_hyprland_version() {
  pacman -Q hyprland 2>/dev/null | awk '{print $2}' || echo "unknown"
}

ob_inv_pacman_explicit() {
  # Explicitly installed packages, native repo only (AUR/foreign listed separately).
  comm -23 \
    <(pacman -Qqe 2>/dev/null | sort) \
    <(pacman -Qqm 2>/dev/null | sort) \
    | jq -R . | jq -s .
}

ob_inv_aur_foreign() {
  pacman -Qqm 2>/dev/null | sort | jq -R . | jq -s .
}

ob_inv_flatpak() {
  if ob_require_tool flatpak; then
    flatpak list --app --columns=application 2>/dev/null | sort | jq -R . | jq -s .
  else
    echo '[]'
  fi
}

ob_inv_appimages() {
  # Best-effort discovery only; AppImages themselves are not embedded in the
  # snapshot (they are large, redistributable binaries) -- just recorded so
  # restore can tell the user what to fetch again.
  local dirs=("$HOME/Applications" "$HOME/.local/bin" "$HOME/Downloads")
  local d f
  {
    for d in "${dirs[@]}"; do
      [ -d "$d" ] || continue
      find "$d" -maxdepth 2 -type f -iname '*.appimage' 2>/dev/null
    done
  } | sort -u | while IFS= read -r f; do
    [ -z "$f" ] && continue
    jq -n --arg path "$f" --arg sha "$(sha256sum -- "$f" 2>/dev/null | awk '{print $1}')" \
      '{path:$path, sha256:$sha}'
  done | jq -s .
}

ob_local_plugin_dirs() {
  # Non-git (self-authored) plugin directories, one path per line. These are
  # embedded in the snapshot payload as-is; git-managed plugins are instead
  # restored via `omarchy plugin add <remote>` (see ob_inv_plugins).
  local plugins_dir="$HOME/.config/omarchy/plugins" d
  [ -d "$plugins_dir" ] || return 0
  for d in "$plugins_dir"/*/; do
    [ -d "$d" ] || continue
    [ -d "$d/.git" ] && continue
    printf '%s\n' "${d%/}"
  done
}

ob_inv_plugins() {
  # Returns: {enabled:[ids], disabled:[ids], git_managed:[{id,remote,commit,dirty}], local_managed:[ids]}
  local plugin_json="[]"
  if ob_require_tool omarchy; then
    plugin_json="$(omarchy plugin list --json 2>/dev/null || echo '[]')"
  fi
  local plugins_dir="$HOME/.config/omarchy/plugins"
  local enabled disabled
  enabled="$(echo "$plugin_json" | jq '[.[] | select(.enabled==true) | .id]')"
  disabled="$(echo "$plugin_json" | jq '[.[] | select(.enabled==false) | .id]')"

  local git_managed="[]" local_managed="[]"
  if [ -d "$plugins_dir" ]; then
    local d id remote commit dirty entry
    for d in "$plugins_dir"/*/; do
      [ -d "$d" ] || continue
      id="$(basename -- "$d")"
      if [ -d "$d/.git" ]; then
        remote="$(git -C "$d" remote get-url origin 2>/dev/null || echo "")"
        commit="$(git -C "$d" rev-parse HEAD 2>/dev/null || echo "")"
        if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then dirty=true; else dirty=false; fi
        local diff=""
        if [ "$dirty" = true ]; then
          diff="$(git -C "$d" diff HEAD 2>/dev/null || true)"
        fi
        entry="$(jq -n --arg id "$id" --arg remote "$remote" --arg commit "$commit" \
          --argjson dirty "$dirty" --arg diff "$diff" \
          '{id:$id, remote:$remote, commit:$commit, dirty:$dirty, diff:$diff}')"
        git_managed="$(echo "$git_managed" | jq --argjson e "$entry" '. + [$e]')"
      else
        local_managed="$(echo "$local_managed" | jq --arg id "$id" '. + [$id]')"
      fi
    done
  fi
  jq -n --argjson enabled "$enabled" --argjson disabled "$disabled" \
    --argjson git_managed "$git_managed" --argjson local_managed "$local_managed" \
    '{enabled:$enabled, disabled:$disabled, git_managed:$git_managed, local_managed:$local_managed}'
}

# Embedded source copy of each declared repo (tracked files as they are in
# the working tree, uncommitted edits included, untracked files and .git
# excluded). Lets a restore work without GitHub access or credentials; the
# clone stays the preferred path. Written deterministically (sorted, fixed
# mtime/owner) so an unchanged repo yields a byte-identical archive and no
# false drift. Lives under the data dir and is picked up by the payload.
OB_REPO_SOURCES_DIR="$OB_DATA_DIR/repo-sources"

ob_repo_source_file() {  # <path relative to $HOME> -> archive path
  printf '%s/%s.tar\n' "$OB_REPO_SOURCES_DIR" "$(printf '%s' "$1" | sed 's|/|__|g')"
}

ob_repo_sources_refresh() {
  local p rel out tmp keep=()
  for p in "${OB_REPOS[@]:-}"; do
    [ -n "$p" ] && [ -d "$p/.git" ] || continue
    case "$p" in "$HOME"/*) rel="${p#"$HOME"/}" ;; *) continue ;; esac
    mkdir -p -- "$OB_REPO_SOURCES_DIR" || return 1
    out="$(ob_repo_source_file "$rel")"
    keep+=("$out")
    tmp="$out.tmp.$$"
    # Only tracked paths that still exist (a deleted-but-tracked file would
    # make tar fail).
    if ! git -C "$p" ls-files -z 2>/dev/null \
        | (cd -- "$p" && while IFS= read -r -d '' f; do
             { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s\0' "$f"
           done) \
        | tar -C "$p" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
            --no-recursion --null -T - -cf "$tmp" 2>/dev/null; then
      rm -f -- "$tmp"
      ob_warn "Could not archive the sources of ~/$rel; a restore will need to clone it."
      continue
    fi
    if cmp -s -- "$tmp" "$out"; then rm -f -- "$tmp"; else mv -f -- "$tmp" "$out"; fi
    chmod 600 -- "$out" 2>/dev/null || true
  done
  # Drop archives of repos that are no longer declared.
  local f k found
  for f in "$OB_REPO_SOURCES_DIR"/*.tar; do
    [ -e "$f" ] || continue
    found=false
    for k in "${keep[@]:-}"; do [ "$k" = "$f" ] && found=true && break; done
    [ "$found" = true ] || rm -f -- "$f"
  done
  return 0
}

ob_inv_repos() {
  # Own git checkouts declared with `repo <path>` in paths.conf/paths.d.
  # Like git-managed plugins: metadata only (remote, branch, commit, tracked
  # diff), never the tree itself. Paths are stored relative to $HOME so a
  # restore onto a different $HOME lands in the same place.
  # Returns: [{path, remote, branch, commit, dirty, diff, ahead, untracked, missing}]
  local p rel remote branch commit dirty diff ahead untracked
  for p in "${OB_REPOS[@]:-}"; do
    [ -n "$p" ] || continue
    case "$p" in "$HOME"/*) rel="${p#"$HOME"/}" ;; *) continue ;; esac
    if [ ! -d "$p/.git" ]; then
      jq -n --arg path "$rel" '{path:$path, missing:true}'
      continue
    fi
    remote="$(git -C "$p" remote get-url origin 2>/dev/null || echo "")"
    branch="$(git -C "$p" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")"
    commit="$(git -C "$p" rev-parse HEAD 2>/dev/null || echo "")"
    diff="$(git -C "$p" diff HEAD 2>/dev/null || true)"
    if [ -n "$diff" ]; then dirty=true; else dirty=false; fi
    # Commits the remote does not have (-1: no upstream configured).
    ahead="$(git -C "$p" rev-list --count '@{u}..HEAD' 2>/dev/null || echo -1)"
    untracked="$(git -C "$p" ls-files --others --exclude-standard 2>/dev/null | wc -l)"
    local src; src="$(ob_repo_source_file "$rel")"
    if [ -f "$src" ]; then src="${src#"$HOME"/}"; else src=""; fi
    jq -n --arg path "$rel" --arg remote "$remote" --arg branch "$branch" --arg commit "$commit" \
      --argjson dirty "$dirty" --arg diff "$diff" --argjson ahead "$ahead" --argjson untracked "$untracked" \
      --arg source_archive "$src" \
      '{path:$path, remote:$remote, branch:$branch, commit:$commit, dirty:$dirty, diff:$diff,
        ahead:$ahead, untracked:$untracked, source_archive:$source_archive, missing:false}'
  done | jq -s .
}

ob_inv_systemd_user_units() {
  # Only units that have an actual file in ~/.config/systemd/user (i.e. hand
  # authored / installed by the user, not vendor units enabled via .wants).
  local dir="$HOME/.config/systemd/user"
  [ -d "$dir" ] || { echo '[]'; return; }
  local f name enabled active
  find "$dir" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.path' \) 2>/dev/null \
    | sort | while IFS= read -r f; do
    name="$(basename -- "$f")"
    enabled="$(systemctl --user is-enabled "$name" 2>/dev/null || echo "disabled")"
    active="$(systemctl --user is-active "$name" 2>/dev/null || echo "inactive")"
    jq -n --arg name "$name" --arg enabled "$enabled" --arg active "$active" \
      '{name:$name, enabled:$enabled, active:$active}'
  done | jq -s .
}

ob_inv_all() {
  jq -n \
    --arg omarchy_version "$(ob_inv_omarchy_version)" \
    --arg kernel "$(ob_inv_kernel_version)" \
    --arg hyprland_version "$(ob_inv_hyprland_version)" \
    --argjson pacman_explicit "$(ob_inv_pacman_explicit)" \
    --argjson aur_foreign "$(ob_inv_aur_foreign)" \
    --argjson flatpak "$(ob_inv_flatpak)" \
    --argjson appimages "$(ob_inv_appimages)" \
    --argjson plugins "$(ob_inv_plugins)" \
    --argjson systemd_user_units "$(ob_inv_systemd_user_units)" \
    --argjson repos "$(ob_inv_repos)" \
    '{
      omarchy_version:$omarchy_version,
      kernel:$kernel,
      hyprland_version:$hyprland_version,
      packages: {pacman_explicit:$pacman_explicit, aur_foreign:$aur_foreign, flatpak:$flatpak, appimages:$appimages},
      plugins:$plugins,
      systemd_user_units:$systemd_user_units,
      repos:$repos
    }'
}
