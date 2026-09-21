#!/bin/bash
# Baseline marking and GREEN/YELLOW/RED drift status against the baseline.

ob_baseline_mark() {
  local name="$1"
  ob_require_snapshot_name "$name"
  local dir="$OB_SNAPSHOTS_DIR/$name"
  [ -f "$dir/manifest.json" ] || ob_die "No such snapshot: $name"

  local state; state="$(ob_state_read)"
  state="$(echo "$state" | jq --arg n "$name" '.snapshots |= map(.baseline = (.name==$n))')"
  ob_state_write "$state"

  local manifest; manifest="$(jq '.baseline = true' "$dir/manifest.json")"
  echo "$manifest" > "$dir/manifest.json"
  ob_info "Marked '$name' as baseline."
}

# Computes the include-root "bucket" a file belongs to, for human-readable
# grouping of file-level drift (e.g. many changed files under ~/.config/hypr
# should be reported once as "~/.config/hypr/", not file by file).
ob_bucket_for_file() {
  local f="$1" best="" best_len=0 root bare
  for root in "${OB_INCLUDES[@]}"; do
    bare="${root%%[*?]*}"
    bare="${bare%/}"
    [ -z "$bare" ] && continue
    case "$f" in
      "$bare"|"$bare"/*)
        if [ "${#bare}" -gt "$best_len" ]; then
          best="$bare"
          best_len="${#bare}"
        fi
        ;;
    esac
  done
  if [ -z "$best" ]; then
    echo "$f"
  else
    echo "~${best#"$HOME"}/"
  fi
}

# Prints a sorted, de-duplicated list of buckets for a list of file paths
# relative to $HOME (one per line on stdin, as stored in checksums.sha256).
ob_buckets_for_files() {
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    ob_bucket_for_file "$HOME/$f"
  done | sort -u
}

ob_status() {
  ob_ensure_dirs
  ob_load_config
  ob_read_path_rules
  ob_state_init_if_missing

  local red_reasons=()
  local tool
  for tool in jq zstd tar sha256sum; do
    ob_require_tool "$tool" || red_reasons+=("required tool missing: $tool")
  done

  local baseline_name; baseline_name="$(ob_state_baseline_name)"
  if [ -z "$baseline_name" ]; then
    echo "Status: UNKNOWN (no baseline set yet -- run: omarchy-backup baseline <snapshot-name>)"
    return 0
  fi
  local bdir="$OB_SNAPSHOTS_DIR/$baseline_name"
  if [ ! -f "$bdir/manifest.json" ] || [ ! -f "$bdir/checksums.sha256" ] || [ ! -f "$bdir/payload.tar.zst" ]; then
    red_reasons+=("baseline snapshot '$baseline_name' is missing manifest/checksums/payload")
  else
    local stored_sha actual_sha
    stored_sha="$(jq -r '.payload.sha256' "$bdir/manifest.json")"
    actual_sha="$(sha256sum -- "$bdir/payload.tar.zst" | awk '{print $1}')"
    [ "$stored_sha" = "$actual_sha" ] || red_reasons+=("baseline payload checksum mismatch (corrupt archive)")
  fi

  if [ "${#red_reasons[@]}" -gt 0 ]; then
    echo "Status: RED"
    echo
    echo "FAIL:"
    printf '  %s\n' "${red_reasons[@]}"
    return 0
  fi

  # --- live inventory & files ---
  local live_inv; live_inv="$(ob_inv_all)"
  local OB_SKIPPED_LARGE=() OB_SKIPPED_SECRET=()
  ob_resolve_included_files
  local live_checksums; live_checksums="$(mktemp)"
  ob_write_checksums "$live_checksums" "${OB_RESOLVED_FILES[@]}"

  local added_files=() changed_files=() removed_files=()
  local btmp ltmp
  btmp="$(mktemp)"; ltmp="$(mktemp)"
  awk '{h=$1; $1=""; sub(/^ /,""); print $0"\t"h}' "$bdir/checksums.sha256" | sort -k1,1 > "$btmp"
  awk '{h=$1; $1=""; sub(/^ /,""); print $0"\t"h}' "$live_checksums" | sort -k1,1 > "$ltmp"

  while IFS=$'\t' read -r path hash; do
    [ -z "$path" ] && continue
    local lh; lh="$(awk -F'\t' -v p="$path" '$1==p{print $2; exit}' "$ltmp")"
    if [ -z "$lh" ]; then
      removed_files+=("$path")
    elif [ "$lh" != "$hash" ]; then
      changed_files+=("$path")
    fi
  done < "$btmp"

  while IFS=$'\t' read -r path hash; do
    [ -z "$path" ] && continue
    if ! grep -qF "$path"$'\t' "$btmp"; then
      added_files+=("$path")
    fi
  done < "$ltmp"
  rm -f "$btmp" "$ltmp" "$live_checksums"

  # --- packages ---
  local bpkgs lpkgs added_pkgs removed_pkgs
  bpkgs="$(jq -r '(.packages.pacman_explicit + .packages.aur_foreign)[]' "$bdir/manifest.json" | sort -u)"
  lpkgs="$(echo "$live_inv" | jq -r '(.packages.pacman_explicit + .packages.aur_foreign)[]' | sort -u)"
  added_pkgs="$(comm -13 <(echo "$bpkgs") <(echo "$lpkgs"))"
  removed_pkgs="$(comm -23 <(echo "$bpkgs") <(echo "$lpkgs"))"

  # --- plugins ---
  local benabled lenabled added_plugins removed_plugins changed_plugins=()
  benabled="$(jq -r '.plugins.enabled[]' "$bdir/manifest.json" | sort -u)"
  lenabled="$(echo "$live_inv" | jq -r '.plugins.enabled[]' | sort -u)"
  added_plugins="$(comm -13 <(echo "$benabled") <(echo "$lenabled"))"
  removed_plugins="$(comm -23 <(echo "$benabled") <(echo "$lenabled"))"
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    local bcommit lcommit bdirty ldirty
    bcommit="$(jq -r --arg id "$id" '.plugins.git_managed[] | select(.id==$id) | .commit' "$bdir/manifest.json")"
    lcommit="$(echo "$live_inv" | jq -r --arg id "$id" '.plugins.git_managed[] | select(.id==$id) | .commit')"
    bdirty="$(jq -r --arg id "$id" '.plugins.git_managed[] | select(.id==$id) | .dirty' "$bdir/manifest.json")"
    ldirty="$(echo "$live_inv" | jq -r --arg id "$id" '.plugins.git_managed[] | select(.id==$id) | .dirty')"
    if [ -n "$bcommit" ] && { [ "$bcommit" != "$lcommit" ] || [ "$bdirty" != "$ldirty" ]; }; then
      changed_plugins+=("$id")
    fi
  done < <(jq -r '.plugins.git_managed[].id' "$bdir/manifest.json")

  local changed_buckets added_buckets removed_buckets
  changed_buckets="$(printf '%s\n' "${changed_files[@]:-}" | ob_buckets_for_files)"
  added_buckets="$(printf '%s\n' "${added_files[@]:-}" | ob_buckets_for_files)"
  removed_buckets="$(printf '%s\n' "${removed_files[@]:-}" | ob_buckets_for_files)"

  local any_drift=false
  [ -n "$changed_buckets" ] && any_drift=true
  [ -n "$added_buckets" ] && any_drift=true
  [ -n "$removed_buckets" ] && any_drift=true
  [ -n "$added_pkgs" ] && any_drift=true
  [ -n "$removed_pkgs" ] && any_drift=true
  [ -n "$added_plugins" ] && any_drift=true
  [ -n "$removed_plugins" ] && any_drift=true
  [ "${#changed_plugins[@]}" -gt 0 ] && any_drift=true

  if [ "$any_drift" = false ]; then
    echo "Status: GREEN (matches baseline '$baseline_name')"
    return 0
  fi

  echo "Status: YELLOW (drift against baseline '$baseline_name')"
  echo
  if [ -n "$changed_buckets" ] || [ "${#changed_plugins[@]}" -gt 0 ]; then
    echo "Changed:"
    [ -n "$changed_buckets" ] && echo "$changed_buckets" | sed 's/^/  /'
    for p in "${changed_plugins[@]:-}"; do [ -n "$p" ] && echo "  plugin: $p"; done
  fi
  if [ -n "$added_buckets" ] || [ -n "$added_pkgs" ] || [ -n "$added_plugins" ]; then
    echo
    echo "Added:"
    [ -n "$added_buckets" ] && echo "$added_buckets" | sed 's/^/  /'
    [ -n "$added_pkgs" ] && echo "$added_pkgs" | sed 's/^/  package: /'
    [ -n "$added_plugins" ] && echo "$added_plugins" | sed 's/^/  plugin: /'
  fi
  if [ -n "$removed_buckets" ] || [ -n "$removed_pkgs" ] || [ -n "$removed_plugins" ]; then
    echo
    echo "Removed:"
    [ -n "$removed_buckets" ] && echo "$removed_buckets" | sed 's/^/  /'
    [ -n "$removed_pkgs" ] && echo "$removed_pkgs" | sed 's/^/  package: /'
    [ -n "$removed_plugins" ] && echo "$removed_plugins" | sed 's/^/  plugin: /'
  fi
}

ob_status_color_only() {
  # Consume the complete status output before selecting its first line.
  # Piping ob_status directly into `head` closed stdout early and produced
  # misleading "echo: write error: Broken pipe" messages on YELLOW status.
  local status_output first_line color
  status_output="$(ob_status)" || return 1
  first_line="${status_output%%$'\n'*}"
  color="${first_line#Status: }"
  printf '%s\n' "${color%% *}"
}
