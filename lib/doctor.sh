#!/bin/bash
# Compatibility / "decay" check: is this tool still able to snapshot,
# diff and restore this Omarchy system? Run manually (`omarchy-backup
# doctor`) or on a timer (`omarchy-backup doctor --auto`).

OB_DOCTOR_LINES=()
OB_DOCTOR_WARN=()
OB_DOCTOR_FAIL=()

ob_doctor_check() {
  # ob_doctor_check "Label" "OK|WARN|FAIL" "detail (for WARN/FAIL)"
  local label="$1" status="$2" detail="${3:-}"
  OB_DOCTOR_LINES+=("$(printf '%-28s %s' "$label" "$status")")
  [ "$status" = "WARN" ] && OB_DOCTOR_WARN+=("$label: $detail")
  [ "$status" = "FAIL" ] && OB_DOCTOR_FAIL+=("$label: $detail")
}

ob_doctor_run() {
  local auto="${1:-false}"
  ob_ensure_dirs
  ob_load_config
  ob_read_path_rules
  ob_state_init_if_missing
  OB_DOCTOR_LINES=(); OB_DOCTOR_WARN=(); OB_DOCTOR_FAIL=()

  # Omarchy version detected
  local ov; ov="$(ob_inv_omarchy_version)"
  if [ "$ov" != "unknown" ] && [ -n "$ov" ]; then
    ob_doctor_check "Omarchy version" "OK"
  else
    ob_doctor_check "Omarchy version" "FAIL" "\`pacman -Q omarchy\` did not return a version -- Fix: confirm Omarchy is actually installed; if it should be, your pacman database may need repair (\`pacman -Dk\`)."
  fi

  # Expected directories
  local d missing_dirs=()
  for d in "$HOME/.config/hypr" "$HOME/.config/omarchy" "$HOME/.config/omarchy/plugins"; do
    [ -d "$d" ] || missing_dirs+=("$d")
  done
  if [ "${#missing_dirs[@]}" -eq 0 ]; then
    ob_doctor_check "Expected directories" "OK"
  else
    ob_doctor_check "Expected directories" "FAIL" "missing: ${missing_dirs[*]} -- Fix: an Omarchy update may have moved these; check for a newer omarchy-backup version, or report this if it looks like a genuine layout change."
  fi

  # Plugin detection
  if ob_require_tool omarchy && omarchy plugin list --json >/dev/null 2>&1; then
    ob_doctor_check "Plugin detection" "OK"
  else
    ob_doctor_check "Plugin detection" "WARN" "\`omarchy plugin list --json\` failed or omarchy CLI missing; plugin inventory will be incomplete -- Fix: run that command yourself to see the error; if Omarchy changed its output format, this tool needs updating."
  fi

  # Package inventory
  if pacman -Qqe >/dev/null 2>&1; then
    ob_doctor_check "Package detection" "OK"
  else
    ob_doctor_check "Package detection" "FAIL" "\`pacman -Qqe\` failed -- Fix: run it directly to see why (a locked or corrupt pacman database is the usual cause: check for a stray /var/lib/pacman/db.lck)."
  fi

  # Config paths from paths.conf actually resolve to something
  local any_present=false
  for root in "${OB_INCLUDES[@]}"; do
    for expanded in $root; do
      [ -e "$expanded" ] && any_present=true && break 2
    done
  done
  if [ "$any_present" = true ]; then
    ob_doctor_check "Config paths" "OK"
  else
    ob_doctor_check "Config paths" "FAIL" "none of the paths in $OB_PATHS_FILE (or paths.d/) exist -- Fix: edit $OB_PATHS_FILE (or add a drop-in under $OB_PATHS_D_DIR) to match where your config actually lives now."
  fi

  # Machine memory readable
  if compgen -G "$HOME/.claude/projects/*/memory" >/dev/null 2>&1; then
    ob_doctor_check "Machine memory" "OK"
  else
    ob_doctor_check "Machine memory" "WARN" "no ~/.claude/projects/*/memory directory found -- Fix: harmless if you simply haven't used Claude Code's memory feature yet; otherwise check whether that path moved."
  fi

  # Agent configuration + shared symlink structure
  local sym_ok=true sym_detail=""
  for pair in "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md" "$HOME/.gemini/GEMINI.md"; do
    if [ -L "$pair" ]; then
      [ -e "$pair" ] || { sym_ok=false; sym_detail="$sym_detail broken symlink: $pair;"; }
    else
      sym_ok=false; sym_detail="$sym_detail not a symlink (or missing): $pair;"
    fi
  done
  if [ "$sym_ok" = true ]; then
    ob_doctor_check "Agent configuration" "OK"
  else
    ob_doctor_check "Agent configuration" "WARN" "$sym_detail -- Fix: recreate the missing symlink(s), e.g. \`ln -sf ~/.config/ai-agents/AGENTS.md ~/.claude/CLAUDE.md\`."
  fi

  # systemd units/timers we manage
  local unit_problem=""
  for u in omarchy-backup-snapshot.timer omarchy-backup-doctor.timer; do
    if systemctl --user list-unit-files "$u" 2>/dev/null | grep -q "$u"; then
      systemctl --user cat "$u" >/dev/null 2>&1 || unit_problem="$unit_problem $u(unreadable)"
    fi
  done
  if [ -z "$unit_problem" ]; then
    ob_doctor_check "systemd units" "OK"
  else
    ob_doctor_check "systemd units" "WARN" "problem with:$unit_problem -- Fix: run \`omarchy-backup timers install\` again to rewrite them."
  fi

  # Remote backup
  if ! ob_remote_configured; then
    ob_doctor_check "Remote backup" "WARN" "not configured -- Fix: set a backup destination (bar widget Options, or \`omarchy-backup config set OB_CFG_REMOTE_PATH <absolute-folder>\`)."
  elif ob_remote_check; then
    ob_doctor_check "Remote backup" "OK"
  else
    ob_doctor_check "Remote backup" "FAIL" "destination '$(ob_remote_base)' not reachable/writable -- Fix: check it's mounted/reachable and you have write permission there."
  fi

  # Can we still create a snapshot? (tools + writable data dir; no actual snapshot taken)
  local tool_missing=""
  for t in jq zstd tar sha256sum rclone timeout; do
    ob_require_tool "$t" || tool_missing="$tool_missing $t"
  done
  if [ -w "$OB_DATA_DIR" ] && [ -z "$tool_missing" ]; then
    ob_doctor_check "Snapshot capability" "OK"
  else
    ob_doctor_check "Snapshot capability" "FAIL" "missing tools:${tool_missing:-none}; data dir writable: $([ -w "$OB_DATA_DIR" ] && echo yes || echo no) -- Fix: install missing tools (\`pacman -S jq zstd tar rclone coreutils\`) and/or fix ownership/permissions on $OB_DATA_DIR."
  fi

  # Manifest schema + checksum validity of the most recent local snapshot
  local latest; latest="$(ob_state_read | jq -r '.snapshots | sort_by(.created_at) | reverse | .[0].name // empty')"
  if [ -z "$latest" ]; then
    ob_doctor_check "Snapshot manifest" "WARN" "no local snapshots yet -- Fix: create one (bar widget \"Snapshot now\", or \`omarchy-backup snapshot\`)."
    ob_doctor_check "Checksum validity" "WARN" "no local snapshots yet -- Fix: create one (bar widget \"Snapshot now\", or \`omarchy-backup snapshot\`)."
  else
    local mf="$OB_SNAPSHOTS_DIR/$latest/manifest.json"
    if jq -e '.schema_version and .payload and .packages and .plugins' "$mf" >/dev/null 2>&1; then
      ob_doctor_check "Snapshot manifest" "OK"
    else
      ob_doctor_check "Snapshot manifest" "FAIL" "manifest.json for '$latest' is missing expected fields -- Fix: this snapshot is corrupt; delete it and create a new one (\`omarchy-backup snapshot --replace $latest\`)."
    fi
    local stored actual
    stored="$(jq -r .payload.sha256 "$mf" 2>/dev/null)"
    actual="$(sha256sum -- "$OB_SNAPSHOTS_DIR/$latest/payload.tar.zst" 2>/dev/null | awk '{print $1}')"
    if [ -n "$stored" ] && [ "$stored" = "$actual" ]; then
      ob_doctor_check "Checksum validity" "OK"
    else
      ob_doctor_check "Checksum validity" "FAIL" "payload checksum mismatch for '$latest' -- Fix: this snapshot's archive is corrupt (disk error?); create a new one (\`omarchy-backup snapshot --replace $latest\`)."
    fi
  fi

  # Restore plausibility: the commands restore.sh relies on still exist
  local restore_tools_missing=""
  for t in pacman git systemctl; do
    ob_require_tool "$t" || restore_tools_missing="$restore_tools_missing $t"
  done
  ob_require_tool omarchy || restore_tools_missing="$restore_tools_missing omarchy"
  if [ -z "$restore_tools_missing" ]; then
    ob_doctor_check "Restore plausibility" "OK"
  else
    ob_doctor_check "Restore plausibility" "WARN" "missing:$restore_tools_missing -- Fix: install the missing command(s) so a future restore can actually run."
  fi

  # --- print report ---
  printf '%s\n' "${OB_DOCTOR_LINES[@]}"
  echo
  if [ "${#OB_DOCTOR_WARN[@]}" -gt 0 ]; then
    echo "WARN:"
    printf '  %s\n' "${OB_DOCTOR_WARN[@]}"
  fi
  if [ "${#OB_DOCTOR_FAIL[@]}" -gt 0 ]; then
    echo "FAIL:"
    printf '  %s\n' "${OB_DOCTOR_FAIL[@]}"
  fi

  local overall="HEALTHY"
  if [ "${#OB_DOCTOR_WARN[@]}" -gt 0 ] || [ "${#OB_DOCTOR_FAIL[@]}" -gt 0 ]; then
    overall="DEGRADED"
  fi
  [ "${#OB_DOCTOR_WARN[@]}" -gt 0 ] || [ "${#OB_DOCTOR_FAIL[@]}" -gt 0 ] && echo
  echo "Compatibility status: $overall"

  local reasons_json
  reasons_json="$(printf '%s\n' "${OB_DOCTOR_WARN[@]}" "${OB_DOCTOR_FAIL[@]}" 2>/dev/null \
    | jq -R 'select(length>0)' | jq -s .)"

  local state; state="$(ob_state_read)"
  state="$(echo "$state" | jq --arg t "$(date -Iseconds)" --arg s "$overall" --arg ov "$ov" \
    --argjson reasons "$reasons_json" \
    '.last_doctor_run=$t | .last_doctor_status=$s | .last_seen_omarchy_version=$ov | .last_doctor_reasons=$reasons')"
  ob_state_write "$state"

  if [ "$auto" = "true" ] && [ "$overall" = "DEGRADED" ]; then
    ob_notify "omarchy-backup: DEGRADED" "Automatic compatibility check found problems. Run 'omarchy-backup doctor' for details." critical
  fi

  [ "$overall" = "HEALTHY" ]
}
