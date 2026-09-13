#!/bin/bash
# Resolves paths.conf include/exclude rules against the live filesystem and
# builds/verifies per-file checksum listings. Shared by snapshot creation and
# baseline drift checking so both use exactly the same file set.

# Populates OB_RESOLVED_FILES (array of absolute file paths), and appends to
# OB_SKIPPED_LARGE / OB_SKIPPED_SECRET (must be pre-declared by caller).
# Requires OB_INCLUDES / OB_EXCLUDES to already be populated
# (ob_read_path_rules) and OB_CFG_MAX_FILE_SIZE_MB to be set.
ob_resolve_included_files() {
  OB_RESOLVED_FILES=()
  local max_bytes=$(( OB_CFG_MAX_FILE_SIZE_MB * 1024 * 1024 ))
  local root expanded f size

  # Self-authored (non-git) plugin directories are always embedded, in
  # addition to whatever paths.conf lists explicitly (see
  # ob_local_plugin_dirs; git-managed plugins are restored via `omarchy
  # plugin add` instead and are intentionally not embedded here).
  local plugin_includes=() extra
  while IFS= read -r extra; do
    [ -n "$extra" ] && plugin_includes+=("$extra")
  done < <(ob_local_plugin_dirs)

  for root in "${OB_INCLUDES[@]}" "${plugin_includes[@]}"; do
    # Support glob patterns in include entries (e.g. .../plugins/*.service)
    for expanded in $root; do
      [ -e "$expanded" ] || continue
      if [ -d "$expanded" ] && [ ! -L "$expanded" ]; then
        while IFS= read -r -d '' f; do
          ob_resolve_consider_file "$f" "$max_bytes"
        done < <(find "$expanded" -type f -print0 2>/dev/null)
      elif [ -f "$expanded" ] || [ -L "$expanded" ]; then
        ob_resolve_consider_file "$expanded" "$max_bytes"
      fi
    done
  done
}

ob_resolve_consider_file() {
  local f="$1" max_bytes="$2" size
  if ob_matches_any_glob "$f" "${OB_EXCLUDES[@]}"; then
    return 0
  fi
  if ob_matches_any_glob "$f" "${OB_SECRET_GLOBS[@]}"; then
    OB_SKIPPED_SECRET+=("$f")
    return 0
  fi
  if [ -L "$f" ]; then
    OB_RESOLVED_FILES+=("$f")
    return 0
  fi
  size=$(stat -c '%s' -- "$f" 2>/dev/null || echo 0)
  if [ "$size" -gt "$max_bytes" ]; then
    OB_SKIPPED_LARGE+=("$f ($((size / 1024 / 1024))MB)")
    return 0
  fi
  OB_RESOLVED_FILES+=("$f")
}

# Writes a checksum file for the given (absolute) file list, using paths
# relative to $HOME -- this is what makes checksums.sha256 (and the drift
# diff built from it) portable across a restore onto a different machine,
# where $HOME is a real path but not necessarily byte-identical to the one
# the snapshot was taken under (e.g. a differently-named sandbox/test HOME).
# ob_write_checksums <out-file> <file...>
ob_write_checksums() {
  local out="$1"; shift
  : > "$out"
  local f rel
  for f in "$@"; do
    rel="${f#"$HOME"/}"
    if [ -L "$f" ]; then
      printf '%s  %s\n' "symlink:$(readlink -- "$f")" "$rel" >> "$out"
    elif [ -f "$f" ]; then
      printf '%s  %s\n' "$(sha256sum -- "$f" 2>/dev/null | awk '{print $1}')" "$rel" >> "$out"
    fi
  done
}
