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

ob_doctor_unprotected_repos() {
  # Prints one line per at-risk repo: "~/path (reason)".
  local -a roots=()
  local w x
  for w in ${OB_CFG_REPO_SCAN_ROOTS:-}; do
    w="$(ob_expand_path "$w")"
    [ -d "$w" ] && roots+=("$w")
  done
  local oldifs="$IFS"; IFS=$'\n'
  for w in "${OB_INCLUDES[@]:-}"; do
    for x in $w; do
      [ -d "$x" ] && [ ! -L "$x" ] && roots+=("$x")
    done
  done
  IFS="$oldifs"
  [ "${#roots[@]}" -gt 0 ] || return 0
  # Drop duplicates and roots inside another root (scanned once).
  local -a uniq=()
  local a b inside
  for a in "${roots[@]}"; do
    inside=false
    for b in "${roots[@]}"; do
      [ "$a" != "$b" ] && case "$a/" in "${b%/}/"*) inside=true; break ;; esac
    done
    [ "$inside" = true ] && continue
    for b in "${uniq[@]:-}"; do [ "$a" = "$b" ] && inside=true && break; done
    [ "$inside" = true ] || uniq+=("$a")
  done
  roots=("${uniq[@]}")
  local -A seen=()
  local g repo r declared included remotes unpushed reason
  while IFS= read -r -d '' g; do
    repo="$(dirname -- "$g")"
    [ -n "${seen[$repo]:-}" ] && continue
    seen["$repo"]=1
    case "$repo/" in "$HOME/.config/omarchy/plugins/"*|"$OB_DATA_DIR/"*) continue ;; esac
    declared=false
    for r in "${OB_REPOS[@]:-}"; do
      [ -n "$r" ] || continue
      # Exact match: a nested repo's history is not in the outer bundle.
      [ "$repo" = "$r" ] && declared=true && break
    done
    [ "$declared" = true ] && continue
    remotes="$(git -C "$repo" remote 2>/dev/null)"
    unpushed=0
    if [ -n "$remotes" ]; then
      unpushed="$(git -C "$repo" rev-list --count --branches --not --remotes 2>/dev/null || echo 0)"
      [ "$unpushed" -gt 0 ] 2>/dev/null || continue
    elif [ -z "$(git -C "$repo" rev-parse --verify -q HEAD 2>/dev/null)" ]; then
      continue  # no commits yet: no history to lose
    fi
    included=false
    IFS=$'\n'
    for w in "${OB_INCLUDES[@]:-}"; do
      for x in $w; do
        case "$repo/" in "${x%/}/"*) included=true; break 2 ;; esac
      done
    done
    IFS="$oldifs"
    if [ -n "$remotes" ]; then reason="$unpushed unpushed commit(s)"; else reason="no remote"; fi
    if [ "$included" = true ]; then reason="$reason; files backed up, history not"
    else reason="$reason; not backed up"; fi
    printf '~/%s (%s)\n' "${repo#"$HOME"/}" "$reason"
  done < <(find "${roots[@]}" -xdev -maxdepth 4 \( -name node_modules -o -name '.cache' \) -prune \
             -o -name .git -type d -print0 -prune 2>/dev/null)
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

  # Agent memory: only meaningful where Claude Code is in use (its
  # per-project memory is the one agent memory this tool's defaults name).
  # Other agents are not required -- a setup without Claude stays HEALTHY.
  if [ ! -d "$HOME/.claude/projects" ] || compgen -G "$HOME/.claude/projects/*/memory" >/dev/null 2>&1; then
    ob_doctor_check "Machine memory" "OK"
  else
    ob_doctor_check "Machine memory" "WARN" "~/.claude/projects exists but has no */memory directory -- Fix: harmless if you don't use Claude Code's memory feature; otherwise check whether that path moved."
  fi

  # Agent instruction files: whichever agents are set up, a shared
  # instruction file that is a symlink must resolve. Missing files or plain
  # files are fine (not every setup shares one file across agents).
  local sym_detail="" pair
  for pair in "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md" "$HOME/.gemini/GEMINI.md" \
              "$HOME/.config/opencode/AGENTS.md" "$HOME/.copilot/copilot-instructions.md" \
              "$HOME/.grok/AGENTS.md" "$HOME/.config/AGENTS.md" "$HOME/.config/crush/CRUSH.md"; do
    if [ -L "$pair" ] && [ ! -e "$pair" ]; then
      sym_detail="$sym_detail broken symlink: $pair;"
    fi
  done
  if [ -z "$sym_detail" ]; then
    ob_doctor_check "Agent configuration" "OK"
  else
    ob_doctor_check "Agent configuration" "WARN" "$sym_detail -- Fix: point the link at your shared instruction file again (e.g. \`ln -sfn <file> <link>\`) or remove it."
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
  else
    local remote_reason
    if remote_reason="$(ob_remote_ensure_available --check 2>&1)"; then
      ob_doctor_check "Remote backup" "OK"
    else
      remote_reason="$(printf '%s' "$remote_reason" | sed -E 's/^\[[^]]*\] *(ERROR|ERR)? *//' | tail -n 1)"
      ob_doctor_check "Remote backup" "FAIL" "${remote_reason:-destination '$(ob_remote_root)' not available} -- Fix: check it's mounted/reachable and you have write permission there."
    fi
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

  # Own git checkouts: declared ones must be re-clonable, and nothing in
  # ~/.local/bin may point into a checkout a restore would not bring back
  # (the symlink would come back, its target would not).
  local repo_problem="" r top l target
  for r in "${OB_REPOS[@]:-}"; do
    [ -n "$r" ] || continue
    # No origin is fine: the snapshot carries the history as a git bundle.
    [ -d "$r/.git" ] || repo_problem="$repo_problem $r(not a git checkout);"
  done
  local -A undeclared=()
  for l in "$HOME/.local/bin"/*; do
    [ -L "$l" ] || continue
    target="$(readlink -f -- "$l" 2>/dev/null)" || continue
    [ -e "$target" ] || continue
    case "$target" in "$HOME/.config/omarchy/plugins/"*) continue ;; esac
    top="$(git -C "$(dirname -- "$target")" rev-parse --show-toplevel 2>/dev/null)" || continue
    [ -n "$top" ] || continue
    local declared=false
    for r in "${OB_REPOS[@]:-}"; do
      [ "$(readlink -f -- "$r" 2>/dev/null)" = "$top" ] && declared=true && break
    done
    [ "$declared" = true ] || undeclared["$top"]=1
  done
  for top in "${!undeclared[@]}"; do
    repo_problem="$repo_problem ~/.local/bin links into $top, which is not declared;"
  done
  if [ -z "$repo_problem" ]; then
    ob_doctor_check "Own git checkouts" "OK"
  else
    ob_doctor_check "Own git checkouts" "WARN" "$repo_problem -- Fix: add \`repo <path>\` for each checkout to a drop-in under $OB_PATHS_D_DIR, so a restore brings it back with its history."
  fi

  # Git repos whose history no backup covers: no remote at all, or commits
  # no remote has, and not declared with `repo`. Inside an included folder
  # their files are backed up but `.git` is excluded, so the history is
  # silently lost. Looks in the included folders plus OB_CFG_REPO_SCAN_ROOTS,
  # never across filesystems (cloud mounts) and only a few levels deep.
  local unprotected
  unprotected="$(ob_doctor_unprotected_repos)"
  if [ -z "$unprotected" ]; then
    ob_doctor_check "Unprotected git history" "OK"
  else
    local n; n="$(printf '%s\n' "$unprotected" | wc -l)"
    ob_doctor_check "Unprotected git history" "WARN" "$n repo(s):$(printf '%s\n' "$unprotected" | head -n 8 | sed 's/^/ /' | tr '\n' ';')$([ "$n" -gt 8 ] && echo " ...") -- Fix: push to a remote, or add \`repo <path>\` (or \`repo <folder>/*\`) to a drop-in under $OB_PATHS_D_DIR; snapshots then carry what only this machine has of their history (all of it with \`repo <path> full\`)."
  fi

  # Integrity of the destination against this machine's ledger.
  if ob_remote_configured && ob_remote_ensure_available --check >/dev/null 2>&1; then
    local integ_out integ_rc integ_mode
    integ_out="$(ob_integrity_check $([ "$auto" = true ] && echo --notify))"; integ_rc=$?
    integ_mode="$(jq -r '.mode // ""' "$OB_INTEGRITY_STATUS_FILE" 2>/dev/null)"
    if [ "$integ_rc" -eq 1 ]; then
      ob_doctor_check "Destination integrity" "FAIL" "changed outside this machine:$(printf '%s\n' "$integ_out" | sed 's/^/ /' | tr '\n' ';') -- Fix: do NOT restore from these snapshots; delete them on the destination, find out who could write there, then push a fresh snapshot."
    elif [ "$integ_rc" -ne 0 ]; then
      ob_doctor_check "Destination integrity" "WARN" "could not list the destination -- Fix: check the connection, then \`omarchy-backup integrity check\`."
    elif [ "$(ob_ledger_read | jq '.snapshots | length')" -eq 0 ]; then
      ob_doctor_check "Destination integrity" "WARN" "no upload recorded in the integrity ledger yet -- Fix: push a snapshot (\`omarchy-backup push <name>\`); older uploads can be adopted after review with \`omarchy-backup integrity record <name>\`."
    elif [ "$integ_mode" = weak ]; then
      ob_doctor_check "Destination integrity" "WARN" "matches the ledger, but only by size and date: the destination is a mounted cloud folder, and hashing it would download every file -- Fix: set OB_CFG_INTEGRITY_RCLONE_REMOTE to the same folder as an rclone spec (e.g. \"mydrive:backups/omarchy\") to compare the backend's MD5 hashes."
    elif [ "$(jq '.unrecorded | length' "$OB_INTEGRITY_STATUS_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
      ob_doctor_check "Destination integrity" "WARN" "uploaded before the ledger existed:$(jq -r '.unrecorded[]' "$OB_INTEGRITY_STATUS_FILE" | sed 's/^/ /' | tr '\n' ';') -- Fix: check them (restore --dry-run), then \`omarchy-backup integrity record <name>\`, or let retention replace them."
    else
      ob_doctor_check "Destination integrity" "OK"
    fi
  fi

  # Signatures: a key to sign with, and a trust anchor that knows it.
  local sig_key sig_problem=""
  if ! sig_key="$(ob_sig_key)"; then
    sig_problem="no signing key configured (OB_CFG_SIGNING_KEY) -- snapshots are unsigned, so a restore cannot tell a genuine snapshot from a forged one"
  elif [ ! -r "$sig_key" ]; then
    sig_problem="signing key $sig_key is not readable"
  elif [ "$(stat -c %a -- "$sig_key" 2>/dev/null)" != 600 ]; then
    sig_problem="signing key $sig_key must have mode 0600 (is $(stat -c %a -- "$sig_key" 2>/dev/null))"
  else
    local sig_pub sig_allowed sig_anchor_rc
    sig_pub="$(ssh-keygen -y -f "$sig_key" </dev/null 2>/dev/null | awk '{print $1" "$2}')"
    sig_allowed="$(mktemp)"
    ob_sig_build_allowed "$sig_allowed"; sig_anchor_rc=$?
    if [ -z "$sig_pub" ]; then
      sig_problem="cannot read the public part of $sig_key (passphrase? the nightly run cannot sign with it)"
    elif [ "$sig_anchor_rc" -eq 1 ]; then
      sig_problem="no trust anchor configured (OB_CFG_SIGNER_GITHUB or OB_CFG_ALLOWED_SIGNERS) -- a fresh install could not verify anything"
    elif [ "$sig_anchor_rc" -ne 0 ]; then
      sig_problem="trust anchor unusable: $OB_SIG_ANCHOR"
    elif ! grep -qF -- "$sig_pub" "$sig_allowed"; then
      sig_problem="the signing key is not among the keys of $OB_SIG_ANCHOR -- signatures would not verify"
    fi
    rm -f -- "$sig_allowed"
  fi
  if [ -z "$sig_problem" ]; then
    ob_doctor_check "Snapshot signatures" "OK"
  else
    ob_doctor_check "Snapshot signatures" "WARN" "$sig_problem -- Fix: see README, \"Never trust the destination\" (ssh-keygen -t ed25519 -N '' -f ~/.config/omarchy-backup/signing_key; gh ssh-key add --type signing; config set OB_CFG_SIGNING_KEY / OB_CFG_SIGNER_GITHUB)."
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
  local repo_modes; repo_modes="$(ob_repo_modes_report)"
  if [ -n "$repo_modes" ]; then
    echo "Git history in snapshots:"
    printf '%s\n' "$repo_modes"
    echo
  fi
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
