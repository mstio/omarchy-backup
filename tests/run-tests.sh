#!/bin/bash
# Self-contained test suite for omarchy-backup. Runs the real CLI against a
# throwaway $HOME and a local-directory rclone remote -- never touches the
# real system. Safe to re-run any time.
#
#   tests/run-tests.sh
#
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT_DIR/bin:$PATH"

WORK="$(mktemp -d /tmp/omarchy-backup-tests.XXXXXX)"
export RCLONE_CONFIG="$WORK/rclone.conf"
export OMARCHY_BACKUP_PUSH_RETRY_DELAY=0
export OMARCHY_BACKUP_TEST_MODE=true
REMOTE_STORAGE="$WORK/remote-storage"
mkdir -p "$REMOTE_STORAGE"
cat > "$RCLONE_CONFIG" <<EOF
[testlocal]
type = local
EOF

PASS=0
FAIL=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"; else
    fail "$desc (expected [$expected], got [$actual])"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then ok "$desc"; else
    fail "$desc (did not find '$needle')"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if ! echo "$haystack" | grep -qF -- "$needle"; then ok "$desc"; else
    fail "$desc (unexpectedly found '$needle')"
  fi
}

assert_file() {
  local desc="$1" path="$2"
  if [ -e "$path" ]; then ok "$desc"; else fail "$desc (missing: $path)"; fi
}

assert_not_file() {
  local desc="$1" path="$2"
  if [ ! -e "$path" ]; then ok "$desc"; else fail "$desc (unexpected: $path)"; fi
}

new_home() {
  local h="$WORK/$1"
  mkdir -p "$h"
  echo "$h"
}

configure_remote() {
  local home="$1" namespace="${2:-omarchy-backup}"
  sed -i 's/^OB_CFG_REMOTE_NAME=.*/OB_CFG_REMOTE_NAME=testlocal/' "$home/.config/omarchy-backup/config.conf"
  sed -i "s|^OB_CFG_REMOTE_PATH=.*|OB_CFG_REMOTE_PATH=$REMOTE_STORAGE/$namespace|" "$home/.config/omarchy-backup/config.conf"
}

seed_workspace() {
  # A minimal but representative personal workspace: dotfile, script,
  # machine memory, and one non-git ("self-authored") plugin dir.
  local home="$1" suffix="${2:-}"
  mkdir -p "$home/.config/hypr" "$home/.local/bin" \
    "$home/.claude/projects/testproj/memory" \
    "$home/.config/omarchy/plugins/mst.testplugin"
  echo "gaps_in = 5$suffix" > "$home/.config/hypr/looknfeel.lua"
  printf '#!/bin/bash\necho hi%s\n' "$suffix" > "$home/.local/bin/mytool"
  chmod +x "$home/.local/bin/mytool"
  echo "- some fact$suffix" > "$home/.claude/projects/testproj/memory/MEMORY.md"
  echo "id: mst.testplugin" > "$home/.config/omarchy/plugins/mst.testplugin/manifest.json"
}

echo "== 1. init =="
HOME="$(new_home home1)"
export HOME
omarchy-backup init >/dev/null 2>&1
assert_file "config.conf created" "$HOME/.config/omarchy-backup/config.conf"
assert_file "paths.conf created" "$HOME/.config/omarchy-backup/paths.conf"
assert_eq "backup config directory is private" "700" "$(stat -c '%a' "$HOME/.config/omarchy-backup")"
assert_eq "backup config file is private" "600" "$(stat -c '%a' "$HOME/.config/omarchy-backup/config.conf")"

echo "== 2. snapshot + baseline =="
seed_workspace "$HOME"
out="$(omarchy-backup snapshot base --baseline 2>&1)"
assert_contains "snapshot created" "$out" "Snapshot 'base' created"
assert_file "snapshot dir exists" "$HOME/.local/share/omarchy-backup/snapshots/base/manifest.json"
assert_file "payload exists" "$HOME/.local/share/omarchy-backup/snapshots/base/payload.tar.zst"
assert_file "checksums exist" "$HOME/.local/share/omarchy-backup/snapshots/base/checksums.sha256"
assert_eq "snapshot payload is private" "600" "$(stat -c '%a' "$HOME/.local/share/omarchy-backup/snapshots/base/payload.tar.zst")"

echo "== 2b. manual recovery uses only standard zstd/tar/checksum tools =="
BASE_DIR="$HOME/.local/share/omarchy-backup/snapshots/base"
MANUAL_DIR="$WORK/manual-extract"
mkdir -p "$MANUAL_DIR"
zstd -q -d -c "$BASE_DIR/payload.tar.zst" | tar -x -C "$MANUAL_DIR"
assert_eq "manual extraction recovers a known file" "gaps_in = 5" \
  "$(cat "$MANUAL_DIR/.config/hypr/looknfeel.lua")"
assert_eq "manifest payload hash is independently verifiable" \
  "$(jq -r .payload.sha256 "$BASE_DIR/manifest.json")" \
  "$(sha256sum "$BASE_DIR/payload.tar.zst" | awk '{print $1}')"

echo "== 3. status: GREEN on a clean baseline =="
status_out="$(omarchy-backup status 2>&1)"
assert_contains "status GREEN" "$status_out" "Status: GREEN"

echo "== 4. status: YELLOW after drift (changed/added/removed) =="
echo "gaps_in = 999" > "$HOME/.config/hypr/looknfeel.lua"
echo "extra = true" > "$HOME/.config/hypr/extra.lua"
rm "$HOME/.local/bin/mytool"
status_rc=0
status_out="$(omarchy-backup status 2>&1)" || status_rc=$?
assert_eq "status YELLOW exits 0 (removed files, no removed plugins)" "0" "$status_rc"
assert_contains "status YELLOW" "$status_out" "Status: YELLOW"
assert_contains "drift shows changed hypr" "$status_out" "~/.config/hypr/"
assert_contains "drift shows removed local bin" "$status_out" "~/.local/bin/"

# restore the clean state for the following tests
seed_workspace "$HOME"
rm -f "$HOME/.config/hypr/extra.lua"

echo "== 5. checksum-relative-path portability (different \$HOME at restore time) =="
FRESH="$(new_home fresh_home)"
HOME="$FRESH" omarchy-backup init >/dev/null 2>&1
HOME="$FRESH" configure_remote "$FRESH"
HOME="$HOME" configure_remote "$HOME"
push_out="$(omarchy-backup push base 2>&1)"
assert_contains "push uploaded" "$push_out" "Upload complete"
assert_contains "push verified remote copy" "$push_out" "Upload copied; verifying"
restore_out="$(HOME="$FRESH" omarchy-backup restore base --accept-unverified --yes 2>&1)"
assert_contains "restore pulled from remote" "$restore_out" "not found locally; trying remote"
assert_contains "restore integrity ok" "$restore_out" "Payload integrity OK"
assert_contains "restore verified checksums across different \$HOME" "$restore_out" "All restored files verified against the snapshot's checksums."
assert_eq "restored hypr file content matches" "gaps_in = 5" "$(cat "$FRESH/.config/hypr/looknfeel.lua" 2>/dev/null)"
assert_eq "restored memory content matches" "- some fact" "$(cat "$FRESH/.claude/projects/testproj/memory/MEMORY.md" 2>/dev/null)"
assert_file "restored self-authored plugin content" "$FRESH/.config/omarchy/plugins/mst.testplugin/manifest.json"

echo "== 6. restore never silently clobbers a differing existing file =="
FRESH2="$(new_home fresh_home2)"
HOME="$FRESH2" omarchy-backup init >/dev/null 2>&1
HOME="$FRESH2" configure_remote "$FRESH2"
mkdir -p "$FRESH2/.local/bin"
echo "PRE-EXISTING, DO NOT LOSE" > "$FRESH2/.local/bin/mytool"
HOME="$FRESH2" omarchy-backup restore base --accept-unverified --yes >/dev/null 2>&1
bak_count="$(find "$FRESH2/.local/bin" -maxdepth 1 -name 'mytool.bak.*' | wc -l)"
if [ "$bak_count" -ge 1 ]; then ok "pre-existing differing file was backed up, not lost"; else
  fail "pre-existing differing file was NOT backed up"
fi

echo "== 7. dry-run makes no changes =="
FRESH3="$(new_home fresh_home3)"
HOME="$FRESH3" omarchy-backup init >/dev/null 2>&1
HOME="$FRESH3" configure_remote "$FRESH3"
HOME="$FRESH3" omarchy-backup restore base --dry-run >/dev/null 2>&1
if [ ! -e "$FRESH3/.config/hypr/looknfeel.lua" ]; then ok "dry-run restore wrote nothing"; else
  fail "dry-run restore wrote files to disk"
fi

echo "== 8. doctor runs and reports a status line =="
HOME="$(new_home home_doctor)"
omarchy-backup init >/dev/null 2>&1
doctor_out="$(omarchy-backup doctor 2>&1)"
assert_contains "doctor prints compatibility status" "$doctor_out" "Compatibility status:"

echo "== 9. three-slot rotation: 4th snapshot requires an explicit replace =="
HOME="$(new_home home_rotation)"
omarchy-backup init >/dev/null 2>&1
seed_workspace "$HOME"
omarchy-backup snapshot s1 >/dev/null 2>&1
omarchy-backup snapshot s2 >/dev/null 2>&1
omarchy-backup snapshot s3 >/dev/null 2>&1
list_out="$(omarchy-backup list 2>&1)"
assert_contains "three snapshots listed" "$list_out" "s1"
assert_contains "three snapshots listed (s3)" "$list_out" "s3"
# Non-interactive (no TTY) with no --replace: must not silently exceed 3 slots.
out4="$(omarchy-backup snapshot s4 < /dev/null 2>&1)"
count_after="$(omarchy-backup list 2>&1 | tail -n +2 | wc -l)"
assert_eq "still exactly 3 snapshots after a 4th create" "3" "$count_after"
assert_contains "s4 present after auto-replacing oldest" "$(omarchy-backup list 2>&1)" "s4"
if ! omarchy-backup list 2>&1 | grep -q '^s1 '; then ok "oldest non-baseline slot (s1) was replaced"; else
  fail "s1 should have been replaced"
fi

echo "== 10. config set survives values containing spaces =="
# Regression test: config.conf is bash-sourced, so an unquoted
# `KEY=value with spaces` line parses as `KEY=value` + `run command "with spaces..."`
# -- e.g. an rclone remote literally named "gdrive omarchy" silently ran
# `omarchy` (printing its top-level help) on every config load instead of
# being treated as the value. ob_config_set must always quote.
HOME="$(new_home home_config_spaces)"
omarchy-backup init >/dev/null 2>&1
omarchy-backup config set OB_CFG_REMOTE_NAME "gdrive omarchy" >/dev/null 2>&1
got="$(omarchy-backup config get OB_CFG_REMOTE_NAME 2>&1)"
assert_eq "value with a space round-trips intact" "gdrive omarchy" "$got"
list_out="$(omarchy-backup config list 2>&1)"
assert_contains "config list produces valid JSON only (no leaked command output)" \
  "$(echo "$list_out" | jq -e . >/dev/null 2>&1 && echo VALID_JSON || echo INVALID)" "VALID_JSON"
assert_contains "value is single-quoted on disk" \
  "$(grep '^OB_CFG_REMOTE_NAME=' "$HOME/.config/omarchy-backup/config.conf")" \
  "OB_CFG_REMOTE_NAME='gdrive omarchy'"

echo "== 11. remote destination: plain local/mounted folder (no rclone remote name) =="
# This is the bar widget's native-folder-picker mode: OB_CFG_REMOTE_NAME
# empty, OB_CFG_REMOTE_PATH an absolute path -- rclone treats a bare path
# as its own local backend, no remote needed.
HOME="$(new_home home_local_dest)"
omarchy-backup init >/dev/null 2>&1
seed_workspace "$HOME"
LOCAL_DEST="$WORK/local-backup-dest"
mkdir -p "$LOCAL_DEST"
sed -i "s|^OB_CFG_REMOTE_PATH=.*|OB_CFG_REMOTE_PATH=$LOCAL_DEST|" "$HOME/.config/omarchy-backup/config.conf"
omarchy-backup snapshot localdest --baseline >/dev/null 2>&1
push_out="$(omarchy-backup push localdest 2>&1)"
assert_contains "push to a plain local path succeeds" "$push_out" "Upload complete"
assert_file "snapshot payload landed under the local destination" \
  "$LOCAL_DEST/$(hostname)/localdest/payload.tar.zst"
doctor_out="$(omarchy-backup doctor 2>&1)"
assert_contains "doctor sees the local-path destination as configured (not WARN)" \
  "$doctor_out" "Remote backup                OK"

echo "== 12. automatic YELLOW snapshots are pushed; GREEN is skipped =="
HOME="$(new_home home_auto_push)"
omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" auto-push
seed_workspace "$HOME"
omarchy-backup snapshot auto-base --baseline >/dev/null 2>&1
omarchy-backup push auto-base >/dev/null 2>&1
green_out="$(omarchy-backup snapshot auto-green --auto 2>&1)"
assert_contains "automatic GREEN run is skipped" "$green_out" "skipping automatic snapshot"
assert_not_file "GREEN run created no snapshot" "$HOME/.local/share/omarchy-backup/snapshots/auto-green"
echo "drift = true" >> "$HOME/.config/hypr/looknfeel.lua"
yellow_out="$(omarchy-backup snapshot auto-yellow --auto 2>&1)"
assert_contains "automatic YELLOW run uploads" "$yellow_out" "Automatic YELLOW snapshot created"
assert_contains "automatic YELLOW upload is verified" "$yellow_out" "Upload complete and verified"
assert_not_contains "automatic status check has no broken-pipe noise" "$yellow_out" "Broken pipe"
assert_file "automatic YELLOW snapshot reached remote" \
  "$REMOTE_STORAGE/auto-push/$(hostname)/auto-yellow/payload.tar.zst"
assert_eq "automatic YELLOW snapshot marked pushed" "true" \
  "$(jq -r '.snapshots[] | select(.name=="auto-yellow") | .remote_pushed' "$HOME/.local/share/omarchy-backup/state.json")"
printf 'corruption' >> "$HOME/.local/share/omarchy-backup/snapshots/auto-base/payload.tar.zst"
red_out="$(omarchy-backup snapshot auto-red --auto 2>&1)"; red_rc=$?
assert_eq "automatic RED run fails closed" "1" "$red_rc"
assert_contains "automatic RED refusal is explained" "$red_out" "refusing to create or upload"
assert_not_file "automatic RED run creates no snapshot" "$HOME/.local/share/omarchy-backup/snapshots/auto-red"

echo "== 13. remote retention permanently protects the baseline =="
HOME="$(new_home home_remote_retention)"
omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" remote-retention
seed_workspace "$HOME"
omarchy-backup snapshot keep-base --baseline >/dev/null 2>&1
omarchy-backup push keep-base >/dev/null 2>&1
for n in rolling-1 rolling-2 rolling-3; do
  echo "$n" >> "$HOME/.config/hypr/looknfeel.lua"
  omarchy-backup snapshot "$n" < /dev/null >/dev/null 2>&1
  omarchy-backup push "$n" >/dev/null 2>&1
done
REMOTE_HOST_DIR="$REMOTE_STORAGE/remote-retention/$(hostname)"
assert_file "baseline survives remote rotation" "$REMOTE_HOST_DIR/keep-base/payload.tar.zst"
assert_not_file "oldest rolling snapshot is pruned" "$REMOTE_HOST_DIR/rolling-1"
assert_file "newer rolling snapshot retained" "$REMOTE_HOST_DIR/rolling-2/payload.tar.zst"
assert_file "newest rolling snapshot retained" "$REMOTE_HOST_DIR/rolling-3/payload.tar.zst"
assert_eq "remote index contains exactly baseline plus two rolling snapshots" "3" \
  "$(jq '.snapshots | length' "$REMOTE_HOST_DIR/index.json")"
assert_eq "remote index still marks protected baseline" "true" \
  "$(jq -r '.snapshots[] | select(.name=="keep-base") | .baseline' "$REMOTE_HOST_DIR/index.json")"

echo "== 14. corrupt local snapshots and failed remote checks are never indexed =="
HOME="$(new_home home_push_guards)"
omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" push-guards
seed_workspace "$HOME"
omarchy-backup snapshot corrupt >/dev/null 2>&1
printf 'corruption' >> "$HOME/.local/share/omarchy-backup/snapshots/corrupt/payload.tar.zst"
corrupt_out="$(omarchy-backup push corrupt 2>&1)"; corrupt_rc=$?
assert_eq "corrupt local payload makes push fail" "1" "$corrupt_rc"
assert_contains "corrupt local payload is explained" "$corrupt_out" "failed its payload checksum"
assert_not_file "corrupt snapshot never reached remote" \
  "$REMOTE_STORAGE/push-guards/$(hostname)/corrupt"

seed_workspace "$HOME" verify
omarchy-backup snapshot verify-fail >/dev/null 2>&1
FAKE_BIN="$WORK/fake-rclone-bin"
mkdir -p "$FAKE_BIN"
REAL_RCLONE="$(command -v rclone)"
cat > "$FAKE_BIN/rclone" <<EOF
#!/bin/bash
if [ "\${1:-}" = check ]; then exit 42; fi
exec "$REAL_RCLONE" "\$@"
EOF
chmod +x "$FAKE_BIN/rclone"
verify_out="$(PATH="$FAKE_BIN:$PATH" omarchy-backup push verify-fail 2>&1)"; verify_rc=$?
assert_eq "persistently failed rclone check makes push fail temporarily (75)" "75" "$verify_rc"
assert_contains "failed rclone check is explained" "$verify_out" "Remote verification"
assert_contains "failed rclone check is retried before giving up" "$verify_out" "attempt 3 of 3"
assert_eq "unverified snapshot is not marked pushed" "null" \
  "$(jq -r '.snapshots[] | select(.name=="verify-fail") | .remote_pushed // "null"' "$HOME/.local/share/omarchy-backup/state.json")"

echo "== 15. snapshot creation fails closed on an unwritable data target =="
HOME="$(new_home home_snapshot_write_failure)"
seed_workspace "$HOME"
touch "$HOME/data-is-a-file"
write_fail_out="$(OMARCHY_BACKUP_DATA_DIR="$HOME/data-is-a-file" omarchy-backup snapshot must-not-exist 2>&1)"; write_fail_rc=$?
assert_eq "snapshot returns failure when its data directory cannot be created" "1" "$write_fail_rc"
assert_contains "snapshot failure explains the backup-directory problem" "$write_fail_out" "Could not create or initialize the backup directories"
assert_not_contains "snapshot failure never reports success" "$write_fail_out" "Snapshot 'must-not-exist' created"

echo "== 16. snapshot names and remote indexes are treated as hostile input =="
HOME="$(new_home home_remote_input_guards)"
omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" remote-input-guards
seed_workspace "$HOME"

bad_name_out="$(omarchy-backup snapshot '../escape' 2>&1)"; bad_name_rc=$?
assert_eq "path-like local snapshot name is rejected" "1" "$bad_name_rc"
assert_contains "snapshot-name rejection explains the grammar" "$bad_name_out" "Invalid snapshot name"
assert_not_file "rejected name cannot escape the snapshot directory" \
  "$HOME/.local/share/omarchy-backup/escape"

omarchy-backup snapshot safe-base --baseline >/dev/null 2>&1
omarchy-backup push safe-base >/dev/null 2>&1
echo drift >> "$HOME/.config/hypr/looknfeel.lua"
omarchy-backup snapshot safe-next >/dev/null 2>&1
REMOTE_HOST_DIR="$REMOTE_STORAGE/remote-input-guards/$(hostname)"
mkdir -p "$REMOTE_STORAGE/remote-input-guards/outside"
echo keep > "$REMOTE_STORAGE/remote-input-guards/outside/sentinel"
jq -n '{schema_version:1,snapshots:[
  {name:"../outside",created_at:"2026-09-21T00:00:00+02:00",baseline:false,omarchy_version:"test",size_bytes:1}
]}' > "$REMOTE_HOST_DIR/index.json"
malicious_out="$(omarchy-backup push safe-next 2>&1)"; malicious_rc=$?
assert_eq "push fails closed on a path-like remote index name" "1" "$malicious_rc"
assert_contains "a rewritten remote index is caught by the integrity ledger first" "$malicious_out" "changed: index.json"
omarchy-backup integrity reset --yes >/dev/null 2>&1
malicious_out="$(omarchy-backup push safe-next 2>&1)"; malicious_rc=$?
assert_eq "without the ledger the index check still fails closed" "1" "$malicious_rc"
assert_contains "unsafe remote index is explained" "$malicious_out" "invalid or unsafe schema"
assert_file "remote index cannot make retention purge outside its prefix" \
  "$REMOTE_STORAGE/remote-input-guards/outside/sentinel"

HANG_BIN="$WORK/hanging-rclone-bin"
mkdir -p "$HANG_BIN"
REAL_TIMEOUT="$(command -v timeout)"
cat > "$HANG_BIN/timeout" <<EOF
#!/bin/bash
for arg in "\$@"; do
  if [ "\$arg" = cat ]; then exit 124; fi
done
exec "$REAL_TIMEOUT" "\$@"
EOF
chmod +x "$HANG_BIN/timeout"
SECONDS=0
hang_out="$(PATH="$HANG_BIN:$PATH" omarchy-backup remote-list 2>&1)"; hang_rc=$?
hang_elapsed=$SECONDS
assert_eq "stalled remote index read fails" "1" "$hang_rc"
assert_contains "stalled read reports the deadline" "$hang_out" "safety deadline"
if [ "$hang_elapsed" -lt 5 ]; then ok "stalled remote index is terminated promptly"; else
  fail "stalled remote index took ${hang_elapsed}s despite the hard deadline"
fi

echo "== 17. git-managed plugins are restored at their pinned commit, never at upstream HEAD =="
# Fixture: an "upstream" plugin repo, a source HOME with it installed, and a
# stub `omarchy` CLI that behaves like the real one for add/enable/list.
UPSTREAM="$WORK/plugin-upstream"
git init -q -b main "$UPSTREAM"
cat > "$UPSTREAM/manifest.json" <<'JSON'
{"schemaVersion":1,"id":"mst.pinned","name":"Pinned","version":"1.0.0","kinds":["bar-widget"],"entryPoints":{"barWidget":"Widget.qml"}}
JSON
echo 'Item {}' > "$UPSTREAM/Widget.qml"
git -C "$UPSTREAM" -c user.name=t -c user.email=t@t add -A
git -C "$UPSTREAM" -c user.name=t -c user.email=t@t commit -q -m "v1"
PINNED="$(git -C "$UPSTREAM" rev-parse HEAD)"

STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/omarchy" <<'STUB'
#!/bin/bash
# Minimal stand-in for the parts of `omarchy plugin ...` the restore uses.
set -uo pipefail
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
case "${1:-} ${2:-}" in
  "plugin list")
    if [ -n "${OMARCHY_STUB_LIST:-}" ] && [ -f "$OMARCHY_STUB_LIST" ]; then cat "$OMARCHY_STUB_LIST"; else echo '[]'; fi ;;
  "plugin add")
    url="$3"; stage="$PLUGINS_DIR/.add.tmp.$$"
    git clone -q -- "$url" "$stage" 2>/dev/null || exit 1
    id="$(jq -r .id "$stage/manifest.json")"
    [ -e "$PLUGINS_DIR/$id" ] && { rm -rf "$stage"; exit 1; }
    mv "$stage" "$PLUGINS_DIR/$id"; echo "Added $id" ;;
  "plugin enable")
    echo "$3" >> "$PLUGINS_DIR/.enabled.log" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/omarchy"

SRC="$(new_home plugin_src_home)"
mkdir -p "$SRC/.config/omarchy/plugins"
git clone -q -- "$UPSTREAM" "$SRC/.config/omarchy/plugins/mst.pinned"
LIST_JSON="$WORK/stub-list.json"
echo '[{"id":"mst.pinned","enabled":true}]' > "$LIST_JSON"
HOME="$SRC" omarchy-backup init >/dev/null 2>&1
HOME="$SRC" OMARCHY_STUB_LIST="$LIST_JSON" PATH="$STUB_BIN:$PATH" omarchy-backup snapshot pinned >/dev/null 2>&1
SNAP_SRC="$SRC/.local/share/omarchy-backup/snapshots/pinned"
assert_eq "snapshot records the plugin's full commit" "$PINNED" \
  "$(jq -r '.plugins.git_managed[] | select(.id=="mst.pinned") | .commit' "$SNAP_SRC/manifest.json")"
assert_eq "snapshot records the plugin as enabled" "mst.pinned" \
  "$(jq -r '.plugins.enabled[0]' "$SNAP_SRC/manifest.json")"

# Upstream moves on after the snapshot: HEAD is now something the user never ran.
echo 'Item { property bool changed: true }' > "$UPSTREAM/Widget.qml"
git -C "$UPSTREAM" -c user.name=t -c user.email=t@t commit -q -am "v2 (never run by the user)"
UPSTREAM_HEAD="$(git -C "$UPSTREAM" rev-parse HEAD)"

restore_into() {
  # restore_into <home-name> <manifest-mutation-jq>  -> prints restore output
  local h; h="$(new_home "$1")"
  local snap="$h/.local/share/omarchy-backup/snapshots/pinned"
  HOME="$h" omarchy-backup init >/dev/null 2>&1
  mkdir -p "$snap"
  cp "$SNAP_SRC/payload.tar.zst" "$SNAP_SRC/checksums.sha256" "$snap/"
  jq "$2" "$SNAP_SRC/manifest.json" > "$snap/manifest.json"
  HOME="$h" PATH="$STUB_BIN:$PATH" omarchy-backup restore pinned --accept-unverified --yes 2>&1
}

RESTORE_HOME="$WORK/plugin_fresh_ok"
out="$(restore_into plugin_fresh_ok '.')"
P="$RESTORE_HOME/.config/omarchy/plugins/mst.pinned"
assert_file "pinned plugin was installed" "$P/.git"
assert_eq "installed plugin is at the pinned commit, not upstream HEAD" "$PINNED" "$(git -C "$P" rev-parse HEAD 2>/dev/null)"
if [ "$PINNED" != "$UPSTREAM_HEAD" ]; then ok "fixture: upstream HEAD differs from the pin"; else fail "fixture: upstream did not move"; fi
assert_eq "installed plugin's origin points at the real upstream" "$UPSTREAM" "$(git -C "$P" remote get-url origin 2>/dev/null)"
assert_contains "pinned plugin was enabled" "$(cat "$RESTORE_HOME/.config/omarchy/plugins/.enabled.log" 2>/dev/null)" "mst.pinned"
assert_not_file "staging clone was cleaned up" "$RESTORE_HOME/.config/omarchy/plugins/.restore.tmp.mst.pinned.$$"

RESTORE_HOME="$WORK/plugin_fresh_missing"
out="$(restore_into plugin_fresh_missing '(.plugins.git_managed[] | select(.id=="mst.pinned") | .commit) |= "0000000000000000000000000000000000000000"')"
assert_not_file "plugin with unavailable pinned commit is not installed" "$RESTORE_HOME/.config/omarchy/plugins/mst.pinned"
assert_not_contains "plugin with unavailable pinned commit is not enabled" "$(cat "$RESTORE_HOME/.config/omarchy/plugins/.enabled.log" 2>/dev/null)" "mst.pinned"
assert_contains "missing pin is reported as a manual step" "$out" "pinned commit 0000000000000000000000000000000000000000 not found"
assert_contains "restore itself still completes" "$out" "Restore of 'pinned' complete"

RESTORE_HOME="$WORK/plugin_fresh_badremote"
out="$(restore_into plugin_fresh_badremote '(.plugins.git_managed[] | select(.id=="mst.pinned") | .remote) |= "ext::sh -c touch%20/tmp/pwned"')"
assert_not_file "plugin with helper-style remote is not cloned" "$RESTORE_HOME/.config/omarchy/plugins/mst.pinned"
assert_contains "helper-style remote is refused" "$out" "not a plain git URL"

RESTORE_HOME="$WORK/plugin_fresh_shortsha"
out="$(restore_into plugin_fresh_shortsha '(.plugins.git_managed[] | select(.id=="mst.pinned") | .commit) |= "abc123"')"
assert_not_file "plugin with a short/partial pin is not installed" "$RESTORE_HOME/.config/omarchy/plugins/mst.pinned"
assert_contains "short pin is refused" "$out" "no full 40-character commit pin"

RESTORE_HOME="$WORK/plugin_fresh_badid"
out="$(restore_into plugin_fresh_badid '(.plugins.git_managed[] | select(.id=="mst.pinned") | .id) |= "../escape"')"
assert_not_file "plugin with a path-like id never creates a directory" "$RESTORE_HOME/.config/omarchy/escape"
assert_contains "path-like plugin id is refused" "$out" "invalid id"

DRY_HOME="$(new_home plugin_fresh_dry)"
HOME="$DRY_HOME" omarchy-backup init >/dev/null 2>&1
mkdir -p "$DRY_HOME/.local/share/omarchy-backup/snapshots"
cp -r "$SNAP_SRC" "$DRY_HOME/.local/share/omarchy-backup/snapshots/pinned"
out="$(HOME="$DRY_HOME" PATH="$STUB_BIN:$PATH" omarchy-backup restore pinned --dry-run 2>&1)"
assert_contains "dry run shows the pin it would enforce" "$out" "pinned at $PINNED"
assert_not_file "dry run clones nothing" "$DRY_HOME/.config/omarchy/plugins/mst.pinned"

echo "== pruned remote snapshots do not break later pushes =="
HOME="$(new_home home_prune_repeat)"
omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" prune-repeat
sed -i 's/^OB_CFG_RETENTION_REMOTE=.*/OB_CFG_RETENTION_REMOTE=2/' "$HOME/.config/omarchy-backup/config.conf"
seed_workspace "$HOME"
for n in pr-1 pr-2 pr-3; do
  omarchy-backup snapshot "$n" >/dev/null 2>&1
  omarchy-backup push "$n" >/dev/null 2>&1
done
out="$(omarchy-backup push pr-3 2>&1)"; rc=$?
assert_eq "re-push after retention pruning succeeds" "0" "$rc"
assert_not_contains "already-pruned snapshot is not reported as a removal failure" "$out" "Could not remove expired"
assert_eq "pruned snapshot is no longer marked as pushed locally" "false" \
  "$(jq -r '.snapshots[] | select(.name=="pr-1") | .remote_pushed' "$HOME/.local/share/omarchy-backup/state.json")"

echo "== a transiently zero-filled index read (caching mount) is retried =="
HOME="$(new_home home_flaky_index)"
omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" flaky-index
seed_workspace "$HOME"
omarchy-backup snapshot fl-1 >/dev/null 2>&1
omarchy-backup push fl-1 >/dev/null 2>&1
FLAKY_BIN="$WORK/flaky-bin"; mkdir -p "$FLAKY_BIN"
REAL_RCLONE="$(command -v rclone)"
cat > "$FLAKY_BIN/rclone" <<FLAKY
#!/bin/bash
# First 'cat' of index.json per marker returns zeros, like a VFS cache race.
if [ "\$1" = "cat" ] && [[ "\$2" == */index.json ]] && [ ! -e "$WORK/flaky-served" ]; then
  touch "$WORK/flaky-served"; head -c 400 /dev/zero; exit 0
fi
exec "$REAL_RCLONE" "\$@"
FLAKY
chmod +x "$FLAKY_BIN/rclone"
omarchy-backup snapshot fl-2 >/dev/null 2>&1
out="$(PATH="$FLAKY_BIN:$PATH" omarchy-backup push fl-2 2>&1)"; rc=$?
assert_file "flaky rclone stub was actually exercised" "$WORK/flaky-served"
assert_eq "push survives one zero-filled index read" "0" "$rc"
assert_not_contains "transient read is not reported as a corrupt index" "$out" "invalid or unsafe schema"

echo "== only the most recently set baseline is protected on the remote =="
HOME="$(new_home home_baseline_switch)"
omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" baseline-switch
sed -i 's/^OB_CFG_RETENTION_REMOTE=.*/OB_CFG_RETENTION_REMOTE=3/' "$HOME/.config/omarchy-backup/config.conf"
seed_workspace "$HOME"
BS_IDX="$REMOTE_STORAGE/baseline-switch/$(hostname)/index.json"
omarchy-backup snapshot bs-old --baseline >/dev/null 2>&1
omarchy-backup push bs-old >/dev/null 2>&1
# The old baseline's local slot rotates away: it now exists only remotely.
jq '.snapshots |= map(select(.name != "bs-old"))' "$HOME/.local/share/omarchy-backup/state.json" > "$WORK/bs-state" \
  && mv "$WORK/bs-state" "$HOME/.local/share/omarchy-backup/state.json"
rm -rf "$HOME/.local/share/omarchy-backup/snapshots/bs-old"
omarchy-backup snapshot bs-new --baseline >/dev/null 2>&1
omarchy-backup push bs-new >/dev/null 2>&1
assert_eq "new manual baseline is the only protected remote baseline" "bs-new" \
  "$(jq -r '[.snapshots[] | select(.baseline==true) | .name] | join(",")' "$BS_IDX")"
assert_eq "remote-only old baseline is demoted" "false" \
  "$(jq -r '.snapshots[] | select(.name=="bs-old") | .baseline' "$BS_IDX")"
omarchy-backup snapshot bs-unpushed >/dev/null 2>&1
omarchy-backup baseline bs-unpushed >/dev/null 2>&1
omarchy-backup snapshot bs-r1 >/dev/null 2>&1
omarchy-backup push bs-r1 >/dev/null 2>&1
assert_eq "remote keeps its baseline while the newly set one is not uploaded yet" "bs-new" \
  "$(jq -r '[.snapshots[] | select(.baseline==true) | .name] | join(",")' "$BS_IDX")"
omarchy-backup snapshot bs-r2 >/dev/null 2>&1
omarchy-backup push bs-r2 >/dev/null 2>&1
assert_not_file "demoted old baseline rotates out like a rolling snapshot" \
  "$REMOTE_STORAGE/baseline-switch/$(hostname)/bs-old"
assert_file "protected baseline survives rotation" \
  "$REMOTE_STORAGE/baseline-switch/$(hostname)/bs-new/payload.tar.zst"
omarchy-backup push bs-unpushed >/dev/null 2>&1
assert_eq "baseline protection moves once the newly set baseline is uploaded" "bs-unpushed" \
  "$(jq -r '[.snapshots[] | select(.baseline==true) | .name] | join(",")' "$BS_IDX")"

echo "== backup destination must be available before any write =="
HOME="$(new_home home_dest_guard)"
omarchy-backup init >/dev/null 2>&1
seed_workspace "$HOME"
GUARD_DEST="$WORK/guard-dest"
mkdir -p "$GUARD_DEST"
sed -i "s|^OB_CFG_REMOTE_NAME=.*|OB_CFG_REMOTE_NAME=''|" "$HOME/.config/omarchy-backup/config.conf"
sed -i "s|^OB_CFG_REMOTE_PATH=.*|OB_CFG_REMOTE_PATH=$GUARD_DEST|" "$HOME/.config/omarchy-backup/config.conf"
omarchy-backup snapshot g-base --baseline >/dev/null 2>&1
out="$(omarchy-backup push g-base 2>&1)"
assert_contains "first push registers the destination" "$out" "Registered backup destination"
assert_file "identity marker written to destination root" "$GUARD_DEST/.omarchy-backup-destination"
guard_id="$(cat "$GUARD_DEST/.omarchy-backup-destination")"

mv "$GUARD_DEST" "$GUARD_DEST.unmounted"          # drive not mounted at all
out="$(omarchy-backup push g-base 2>&1)"; rc=$?
assert_eq "push to a missing destination fails" "1" "$rc"
assert_contains "missing destination is explained" "$out" "does not exist"
assert_not_file "missing destination folder is never recreated" "$GUARD_DEST"

mkdir -p "$GUARD_DEST"                              # empty mountpoint left behind
out="$(omarchy-backup push g-base 2>&1)"; rc=$?
assert_eq "push into an empty mountpoint fails" "1" "$rc"
assert_contains "missing identity marker is explained" "$out" "identity marker"
assert_eq "nothing was written into the empty mountpoint" "0" "$(find "$GUARD_DEST" -mindepth 1 | wc -l)"

echo "drift = true" >> "$HOME/.config/hypr/looknfeel.lua"
out="$(omarchy-backup snapshot g-auto --auto 2>&1)"; rc=$?
assert_eq "automatic run with unavailable destination exits 75 (retry later)" "75" "$rc"
assert_file "local first: the snapshot is still created locally" \
  "$HOME/.local/share/omarchy-backup/snapshots/g-auto/payload.tar.zst"
assert_contains "automatic run explains that only the upload is pending" "$out" "upload will be retried"
assert_eq "nothing was written into the empty mountpoint by the automatic run" "0" "$(find "$GUARD_DEST" -mindepth 1 | wc -l)"
out="$(omarchy-backup snapshot g-retry --auto 2>&1)"; rc=$?
assert_eq "retry while still unavailable exits 75 again" "75" "$rc"
assert_not_file "retry does not create a duplicate snapshot" "$HOME/.local/share/omarchy-backup/snapshots/g-retry"
doctor_out="$(omarchy-backup doctor 2>&1)"
assert_contains "doctor reports the unavailable destination with its reason" "$doctor_out" "identity marker"

rmdir "$GUARD_DEST"; mv "$GUARD_DEST.unmounted" "$GUARD_DEST"   # drive is back
out="$(omarchy-backup snapshot g-retry2 --auto 2>&1)"; rc=$?
assert_eq "retry after the destination is back succeeds" "0" "$rc"
assert_contains "retry uploads the pending local snapshot" "$out" "Uploading pending snapshot 'g-auto'"
assert_not_file "retry after recovery still creates no duplicate" "$HOME/.local/share/omarchy-backup/snapshots/g-retry2"
assert_file "pending snapshot reached the destination" "$GUARD_DEST/$(hostname)/g-auto/payload.tar.zst"
echo "more drift = true" >> "$HOME/.config/hypr/looknfeel.lua"
out="$(omarchy-backup snapshot g-auto3 --auto 2>&1)"
assert_contains "a real change afterwards is snapshotted and uploaded" "$out" "Upload complete and verified"

HOME="$(new_home home_dest_guard_fresh)"          # fresh install, same destination
omarchy-backup init >/dev/null 2>&1
seed_workspace "$HOME"
sed -i "s|^OB_CFG_REMOTE_NAME=.*|OB_CFG_REMOTE_NAME=''|" "$HOME/.config/omarchy-backup/config.conf"
sed -i "s|^OB_CFG_REMOTE_PATH=.*|OB_CFG_REMOTE_PATH=$GUARD_DEST|" "$HOME/.config/omarchy-backup/config.conf"
omarchy-backup snapshot g-fresh >/dev/null 2>&1
out="$(omarchy-backup push g-fresh 2>&1)"
assert_contains "fresh install pushes to an existing destination" "$out" "Upload complete"
assert_not_contains "fresh install adopts the existing marker" "$out" "Registered backup destination"
assert_eq "adopted marker id is remembered" "$guard_id" \
  "$(jq -r --arg d "$GUARD_DEST" '.destinations[$d]' "$HOME/.local/share/omarchy-backup/state.json")"

echo "== a transiently failed upload verification is retried within the push =="
HOME="$(new_home home_push_retry)"
omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" push-retry
seed_workspace "$HOME"
omarchy-backup snapshot retry-once >/dev/null 2>&1
RETRY_BIN="$WORK/retry-once-rclone-bin"
mkdir -p "$RETRY_BIN"
cat > "$RETRY_BIN/rclone" <<RETRY
#!/bin/bash
if [ "\$1" = "check" ] && [ ! -e "$WORK/retry-once-failed" ]; then
  touch "$WORK/retry-once-failed"; exit 1
fi
exec "$REAL_RCLONE" "\$@"
RETRY
chmod +x "$RETRY_BIN/rclone"
retry_out="$(PATH="$RETRY_BIN:$PATH" omarchy-backup push retry-once 2>&1)"; retry_rc=$?
assert_file "retry-once rclone stub was actually exercised" "$WORK/retry-once-failed"
assert_eq "push succeeds after one failed verification" "0" "$retry_rc"
assert_contains "the retry is logged" "$retry_out" "attempt 2 of 3"
assert_contains "the retried upload is verified" "$retry_out" "Upload complete and verified"
assert_eq "retried snapshot is marked pushed" "true" \
  "$(jq -r '.snapshots[] | select(.name=="retry-once") | .remote_pushed' "$HOME/.local/share/omarchy-backup/state.json")"

echo "== automatic run: unverifiable upload exits 75 and a later run catches up =="
HOME="$(new_home home_auto_tempfail)"
omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" auto-tempfail
seed_workspace "$HOME"
omarchy-backup snapshot tf-base --baseline >/dev/null 2>&1
omarchy-backup push tf-base >/dev/null 2>&1
echo "drift = true" >> "$HOME/.config/hypr/looknfeel.lua"
tf_out="$(PATH="$FAKE_BIN:$PATH" omarchy-backup snapshot tf-yellow --auto 2>&1)"; tf_rc=$?
assert_eq "automatic run with unverifiable upload exits 75 (systemd retries)" "75" "$tf_rc"
assert_contains "automatic tempfail explains that the snapshot is safe locally" "$tf_out" "is safe locally"
assert_file "automatic snapshot stays local" "$HOME/.local/share/omarchy-backup/snapshots/tf-yellow/payload.tar.zst"
assert_eq "unverified automatic snapshot is not marked pushed" "null" \
  "$(jq -r '.snapshots[] | select(.name=="tf-yellow") | .remote_pushed // "null"' "$HOME/.local/share/omarchy-backup/state.json")"
catchup_out="$(omarchy-backup snapshot tf-again --auto 2>&1)"; catchup_rc=$?
assert_eq "retry run succeeds once the upload verifies" "0" "$catchup_rc"
assert_contains "retry run uploads the pending snapshot" "$catchup_out" "Uploading pending snapshot 'tf-yellow'"
assert_not_file "retry run creates no duplicate snapshot" "$HOME/.local/share/omarchy-backup/snapshots/tf-again"
assert_eq "pending snapshot is marked pushed after the retry" "true" \
  "$(jq -r '.snapshots[] | select(.name=="tf-yellow") | .remote_pushed' "$HOME/.local/share/omarchy-backup/state.json")"

echo "== own git checkouts (paths.conf: repo) come back on restore =="
G="git -c user.name=t -c user.email=t@t"
REPO_BARE="$WORK/tool-upstream.git"
git init -q --bare -b main "$REPO_BARE"
RSRC="$(new_home repo_src_home)"
HOME="$RSRC" omarchy-backup init >/dev/null 2>&1
git clone -q "$REPO_BARE" "$RSRC/Projects/tool" 2>/dev/null
mkdir -p "$RSRC/Projects/tool/bin" "$RSRC/.local/bin"
printf '#!/bin/bash\necho tool-v1\n' > "$RSRC/Projects/tool/bin/tool"; chmod +x "$RSRC/Projects/tool/bin/tool"
$G -C "$RSRC/Projects/tool" add -A; $G -C "$RSRC/Projects/tool" commit -q -m v1; git -C "$RSRC/Projects/tool" push -q origin main 2>/dev/null
ln -s "$RSRC/Projects/tool/bin/tool" "$RSRC/.local/bin/tool"
# Undeclared first: doctor must point at the checkout behind the link.
doc_out="$(HOME="$RSRC" omarchy-backup doctor 2>&1)"
assert_contains "doctor flags a ~/.local/bin link into an undeclared checkout" "$doc_out" "which is not declared"
echo "repo ~/Projects/tool" > "$RSRC/.config/omarchy-backup/paths.d/repos.conf"
doc_out="$(HOME="$RSRC" omarchy-backup doctor 2>&1)"
assert_contains "doctor accepts the declared checkout" "$doc_out" "$(printf '%-28s %s' 'Own git checkouts' 'OK')"
# Tracked uncommitted edit + an unpushed commit-free state; plus an untracked file.
echo "local tweak" >> "$RSRC/Projects/tool/bin/tool"
echo "scratch" > "$RSRC/Projects/tool/notes.txt"
snap_out="$(HOME="$RSRC" omarchy-backup snapshot withrepo 2>&1)"
RSNAP="$RSRC/.local/share/omarchy-backup/snapshots/withrepo"
assert_eq "manifest records the repo path relative to HOME" "Projects/tool" "$(jq -r '.repos[0].path' "$RSNAP/manifest.json")"
assert_eq "manifest records the repo remote" "$REPO_BARE" "$(jq -r '.repos[0].remote' "$RSNAP/manifest.json")"
assert_eq "manifest records the tracked diff" "true" "$(jq -r '.repos[0].dirty' "$RSNAP/manifest.json")"
assert_contains "snapshot warns about untracked files in the repo" "$snap_out" "untracked file(s) are not part of the backup"
assert_not_contains "the repo tree itself is not embedded" "$(zstd -q -d -c "$RSNAP/payload.tar.zst" | tar -t)" "Projects/tool"
$G -C "$RSRC/Projects/tool" commit -q -am "local only"
assert_contains "symlinks inside included directories are snapshotted" "$(cat "$RSNAP/checksums.sha256")" "symlink:$RSRC/Projects/tool/bin/tool  .local/bin/tool"
snap2_out="$(HOME="$RSRC" omarchy-backup snapshot withrepo2 2>&1)"
assert_not_contains "unpushed commits need no warning: the history bundle carries them" "$snap2_out" "unpushed commit(s)"

repo_restore_into() {
  local h; h="$(new_home "$1")"
  HOME="$h" omarchy-backup init >/dev/null 2>&1
  mkdir -p "$h/.local/share/omarchy-backup/snapshots/withrepo"
  cp "$RSNAP"/* "$h/.local/share/omarchy-backup/snapshots/withrepo/"
  shift
  HOME="$h" omarchy-backup restore withrepo --accept-unverified --yes "$@" 2>&1
}
DRYR="$WORK/repo_dry"
dry_out="$(repo_restore_into repo_dry --dry-run)"
assert_contains "dry run announces the clone" "$dry_out" "[dry-run] clone $REPO_BARE"
assert_not_file "dry run does not clone" "$DRYR/Projects/tool"
FRESHR="$WORK/repo_fresh"
r_out="$(repo_restore_into repo_fresh)"
assert_file "restore re-clones the declared checkout" "$FRESHR/Projects/tool/.git"
assert_eq "restored ~/.local/bin link works again" "tool-v1" "$(HOME="$FRESHR" "$FRESHR/.local/bin/tool" | head -1)"
assert_contains "tracked uncommitted edit is reapplied" "$(cat "$FRESHR/Projects/tool/bin/tool")" "local tweak"
assert_contains "untracked files are reported as not backed up" "$r_out" "untracked file(s) at snapshot time"
# Remote moved on after the snapshot: the newer pushed state wins.
$G -C "$WORK/repo_fresh/Projects/tool" stash -q 2>/dev/null
OTHER="$WORK/tool-other"; git clone -q "$REPO_BARE" "$OTHER" 2>/dev/null
echo "v2" > "$OTHER/CHANGES"; $G -C "$OTHER" add -A; $G -C "$OTHER" commit -q -m v2; git -C "$OTHER" push -q origin main 2>/dev/null
NEWR="$WORK/repo_newer"
n_out="$(repo_restore_into repo_newer)"
assert_eq "restore keeps the newer remote state" "$(git -C "$OTHER" rev-parse HEAD)" "$(git -C "$NEWR/Projects/tool" rev-parse HEAD)"
assert_contains "restore says the remote is newer" "$n_out" "remote is newer than the snapshot"
# An existing non-git directory is never touched.
BLOCK="$(new_home repo_blocked)"; mkdir -p "$BLOCK/Projects/tool"; echo keep > "$BLOCK/Projects/tool/file"
HOME="$BLOCK" omarchy-backup init >/dev/null 2>&1
mkdir -p "$BLOCK/.local/share/omarchy-backup/snapshots/withrepo"; cp "$RSNAP"/* "$BLOCK/.local/share/omarchy-backup/snapshots/withrepo/"
b_out="$(HOME="$BLOCK" omarchy-backup restore withrepo --accept-unverified --yes 2>&1)"
assert_eq "existing non-git directory is left untouched" "keep" "$(cat "$BLOCK/Projects/tool/file")"
assert_contains "the skipped repo is listed as a manual step" "$b_out" "is not a git checkout; not touched"
# Hostile manifest path is refused.
EVIL="$(new_home repo_evil)"; HOME="$EVIL" omarchy-backup init >/dev/null 2>&1
mkdir -p "$EVIL/.local/share/omarchy-backup/snapshots/withrepo"; cp "$RSNAP"/* "$EVIL/.local/share/omarchy-backup/snapshots/withrepo/"
jq '.repos[0].path="../escape"' "$RSNAP/manifest.json" > "$EVIL/.local/share/omarchy-backup/snapshots/withrepo/manifest.json"
e_out="$(HOME="$EVIL" omarchy-backup restore withrepo --accept-unverified --yes 2>&1)"
assert_contains "a repo path escaping HOME is refused" "$e_out" "unsafe path"
assert_not_file "nothing is cloned outside HOME" "$WORK/escape"

echo "== restore without git access: embedded repo copy =="
assert_contains "manifest points at the embedded source copy" "$(jq -r '.repos[0].source_archive' "$RSNAP/manifest.json")" "repo-sources/Projects__tool.tar"
assert_contains "the embedded copy travels in the payload" "$(zstd -q -d -c "$RSNAP/payload.tar.zst" | tar -t)" ".local/share/omarchy-backup/repo-sources/Projects__tool.tar"
SRCS1="$(sha256sum < "$RSRC/.local/share/omarchy-backup/repo-sources/Projects__tool.tar")"
HOME="$RSRC" omarchy-backup snapshot unchanged-src >/dev/null 2>&1
assert_eq "an unchanged repo yields a byte-identical archive (no false drift)" "$SRCS1" \
  "$(sha256sum < "$RSRC/.local/share/omarchy-backup/repo-sources/Projects__tool.tar")"
assert_eq "fully pushed repo: no history bundle (metadata only)" "" "$(jq -r '.repos[0].history_bundle' "$RSNAP/manifest.json")"
OFFR="$WORK/repo_offline"
o_out="$(repo_restore_into repo_offline --repos-from-snapshot)"
assert_file "--repos-from-snapshot restores the tree" "$OFFR/Projects/tool/bin/tool"
assert_not_file "without a bundle the file-only copy has no .git" "$OFFR/Projects/tool/.git"
assert_contains "the file-only copy includes tracked uncommitted edits" "$(cat "$OFFR/Projects/tool/bin/tool")" "local tweak"
assert_not_file "untracked files are not in the embedded copy" "$OFFR/Projects/tool/notes.txt"
assert_eq "restored link works from the embedded copy" "tool-v1" "$(HOME="$OFFR" "$OFFR/.local/bin/tool" 2>/dev/null | head -1 || true)"
assert_contains "restore explains how to reconnect git later" "$o_out" "git remote add origin $REPO_BARE"
DEADR="$(new_home repo_deadremote)"; HOME="$DEADR" omarchy-backup init >/dev/null 2>&1
mkdir -p "$DEADR/.local/share/omarchy-backup/snapshots/withrepo"; cp "$RSNAP"/* "$DEADR/.local/share/omarchy-backup/snapshots/withrepo/"
jq --arg r "$WORK/does-not-exist.git" '.repos[0].remote=$r' "$RSNAP/manifest.json" > "$DEADR/.local/share/omarchy-backup/snapshots/withrepo/manifest.json"
d_out="$(HOME="$DEADR" omarchy-backup restore withrepo --accept-unverified --yes 2>&1)"
assert_file "unreachable remote falls back to the embedded copy" "$DEADR/Projects/tool/bin/tool"
assert_contains "the fallback is reported" "$d_out" "restored from the snapshot's embedded copy (cloning failed)"
# `repo <path> full`: the whole history even though a remote has it.
echo "repo ~/Projects/tool full" > "$RSRC/.config/omarchy-backup/paths.d/repos.conf"
HOME="$RSRC" omarchy-backup snapshot withfull --replace unchanged-src >/dev/null 2>&1
FSNAP="$RSRC/.local/share/omarchy-backup/snapshots/withfull"
assert_eq "\`full\` makes a full bundle despite the remote" "full" "$(jq -r '.repos[0].history_bundle_kind' "$FSNAP/manifest.json")"
FULLR="$(new_home repo_fullr)"; HOME="$FULLR" omarchy-backup init >/dev/null 2>&1
mkdir -p "$FULLR/.local/share/omarchy-backup/snapshots/withfull"; cp "$FSNAP"/* "$FULLR/.local/share/omarchy-backup/snapshots/withfull/"
f_out="$(HOME="$FULLR" omarchy-backup restore withfull --accept-unverified --yes --repos-from-snapshot 2>&1)"
assert_contains "--repos-from-snapshot uses the full bundle" "$f_out" "restored from the snapshot's history bundle (--repos-from-snapshot)"
assert_eq "the full-bundle restore keeps the history" "$(git -C "$RSRC/Projects/tool" rev-parse HEAD)" "$(git -C "$FULLR/Projects/tool" rev-parse HEAD 2>/dev/null)"
assert_eq "the full-bundle restore is complete (connectivity)" "0" "$(git -C "$FULLR/Projects/tool" fsck --connectivity-only >/dev/null 2>&1; echo $?)"
assert_eq "the full-bundle restore sets the recorded origin" "$REPO_BARE" "$(git -C "$FULLR/Projects/tool" remote get-url origin 2>/dev/null)"
assert_contains "the full-bundle restore reapplies tracked uncommitted edits" "$(cat "$FULLR/Projects/tool/bin/tool")" "local tweak"
echo "repo ~/Projects/tool" > "$RSRC/.config/omarchy-backup/paths.d/repos.conf"

echo "== repos without a remote: history bundle, globs, doctor =="
LONE="$(new_home repo_lone_home)"; HOME="$LONE" omarchy-backup init >/dev/null 2>&1
mkdir -p "$LONE/Work/plugin-a" "$LONE/Work/plain-folder" "$LONE/Work/plugin-b"
git init -q -b main "$LONE/Work/plugin-a"
echo v1 > "$LONE/Work/plugin-a/a.php"; $G -C "$LONE/Work/plugin-a" add -A; $G -C "$LONE/Work/plugin-a" commit -q -m one
$G -C "$LONE/Work/plugin-a" tag v1.0
$G -C "$LONE/Work/plugin-a" checkout -q -b feature; echo f > "$LONE/Work/plugin-a/f.php"
$G -C "$LONE/Work/plugin-a" add -A; $G -C "$LONE/Work/plugin-a" commit -q -m feat; $G -C "$LONE/Work/plugin-a" checkout -q main
echo v2 >> "$LONE/Work/plugin-a/a.php"; $G -C "$LONE/Work/plugin-a" commit -q -am two
echo "wip" >> "$LONE/Work/plugin-a/a.php"
echo notes > "$LONE/Work/plain-folder/x.txt"
lone_doc="$(HOME="$LONE" omarchy-backup doctor 2>&1)"
assert_contains "doctor flags an undeclared repo without remote" "$lone_doc" "~/Work/plugin-a (no remote; not backed up)"
echo "include ~/Work" > "$LONE/.config/omarchy-backup/paths.d/work.conf"
lone_doc="$(HOME="$LONE" omarchy-backup doctor 2>&1)"
assert_contains "doctor explains that an included repo loses its history" "$lone_doc" "~/Work/plugin-a (no remote; files backed up, history not)"
# Declared later via a glob: a repo created after the drop-in is picked up too.
echo "repo ~/Work/*" >> "$LONE/.config/omarchy-backup/paths.d/work.conf"
git init -q -b main "$LONE/Work/plugin-b"; echo b > "$LONE/Work/plugin-b/b.php"
$G -C "$LONE/Work/plugin-b" add -A; $G -C "$LONE/Work/plugin-b" commit -q -m b
lone_doc="$(HOME="$LONE" omarchy-backup doctor 2>&1)"
assert_contains "a glob-declared repo without remote is no longer flagged" "$lone_doc" "$(printf '%-28s %s' 'Unprotected git history' 'OK')"
assert_contains "glob-declared repos need no origin" "$lone_doc" "$(printf '%-28s %s' 'Own git checkouts' 'OK')"
lone_snap="$(HOME="$LONE" omarchy-backup snapshot lone 2>&1)"
LSNAP="$LONE/.local/share/omarchy-backup/snapshots/lone"
assert_eq "the glob declares every git checkout (and only those)" "Work/plugin-a Work/plugin-b" "$(jq -r '[.repos[].path] | sort | join(" ")' "$LSNAP/manifest.json")"
assert_not_contains "no 'cannot re-clone' warning when a bundle exists" "$lone_snap" "no origin remote"
assert_contains "the history bundle travels in the payload" "$(zstd -q -d -c "$LSNAP/payload.tar.zst" | tar -t)" ".local/share/omarchy-backup/repo-sources/Work__plugin-a.bundle"
BUN1="$(sha256sum < "$LONE/.local/share/omarchy-backup/repo-sources/Work__plugin-a.bundle")"
HOME="$LONE" omarchy-backup snapshot lone-again >/dev/null 2>&1
assert_eq "an unchanged repo keeps its bundle byte-identical" "$BUN1" "$(sha256sum < "$LONE/.local/share/omarchy-backup/repo-sources/Work__plugin-a.bundle")"
LREST="$(new_home repo_lone_restore)"; HOME="$LREST" omarchy-backup init >/dev/null 2>&1
mkdir -p "$LREST/.local/share/omarchy-backup/snapshots/lone"; cp "$LSNAP"/* "$LREST/.local/share/omarchy-backup/snapshots/lone/"
ldry="$(HOME="$LREST" omarchy-backup restore lone --dry-run 2>&1)"
assert_contains "dry run announces the bundle restore" "$ldry" "rebuild ~/Work/plugin-a from the snapshot's history bundle"
lr_out="$(HOME="$LREST" omarchy-backup restore lone --accept-unverified --yes 2>&1)"
assert_eq "restore rebuilds the history of a repo without remote" "$(git -C "$LONE/Work/plugin-a" rev-parse HEAD)" "$(git -C "$LREST/Work/plugin-a" rev-parse HEAD 2>/dev/null)"
assert_eq "restore brings back the tags" "v1.0" "$(git -C "$LREST/Work/plugin-a" tag 2>/dev/null)"
assert_eq "restore brings back other branches" "$(git -C "$LONE/Work/plugin-a" rev-parse feature)" "$(git -C "$LREST/Work/plugin-a" rev-parse feature 2>/dev/null)"
assert_eq "restore checks out the recorded branch" "main" "$(git -C "$LREST/Work/plugin-a" symbolic-ref --short HEAD 2>/dev/null)"
assert_contains "restore reapplies uncommitted edits on top" "$(cat "$LREST/Work/plugin-a/a.php")" "wip"
assert_eq "a restored repo without remote has none" "" "$(git -C "$LREST/Work/plugin-a" remote 2>/dev/null)"
assert_file "non-git folders under an included path come back as files" "$LREST/Work/plain-folder/x.txt"
assert_eq "restored history has every commit" "$(git -C "$LONE/Work/plugin-a" rev-list --count --all)" "$(git -C "$LREST/Work/plugin-a" rev-list --count --all 2>/dev/null)"

echo "== history bundle: unpushed work on the clone path, edge cases =="
UP_BARE="$WORK/up-upstream.git"; git init -q --bare -b main "$UP_BARE"
UPS="$(new_home repo_up_src)"; HOME="$UPS" omarchy-backup init >/dev/null 2>&1
git clone -q "$UP_BARE" "$UPS/Projects/up" 2>/dev/null
echo one > "$UPS/Projects/up/f"; $G -C "$UPS/Projects/up" add -A; $G -C "$UPS/Projects/up" commit -q -m one
git -C "$UPS/Projects/up" push -q origin main 2>/dev/null
echo two >> "$UPS/Projects/up/f"; $G -C "$UPS/Projects/up" commit -q -am two-unpushed
$G -C "$UPS/Projects/up" tag local-tag
$G -C "$UPS/Projects/up" branch side; $G -C "$UPS/Projects/up" checkout -q side
echo s > "$UPS/Projects/up/s"; $G -C "$UPS/Projects/up" add -A; $G -C "$UPS/Projects/up" commit -q -m side; $G -C "$UPS/Projects/up" checkout -q main
ONE="$(git -C "$UPS/Projects/up" rev-parse HEAD~1)"
$G -C "$UPS/Projects/up" tag pushed-light "$ONE"
$G -C "$UPS/Projects/up" tag -a -m note pushed-annotated "$ONE"
$G -C "$UPS/Projects/up" branch at-pushed "$ONE"
echo "repo ~/Projects/up" > "$UPS/.config/omarchy-backup/paths.d/r.conf"
HOME="$UPS" omarchy-backup snapshot up >/dev/null 2>&1
USNAP="$UPS/.local/share/omarchy-backup/snapshots/up"
assert_eq "delta: manifest says so" "delta" "$(jq -r '.repos[0].history_bundle_kind' "$USNAP/manifest.json")"
assert_eq "delta: counts only the unpushed commits" "2" "$(jq -r '.repos[0].missing_commits' "$USNAP/manifest.json")"
EMPTYG="$WORK/empty-git"; git init -q "$EMPTYG"
assert_contains "delta: the bundle builds on the remote's commits" \
  "$(git -C "$EMPTYG" bundle verify "$UPS/.local/share/omarchy-backup/repo-sources/Projects__up.bundle" 2>&1)" "$ONE"
assert_eq "delta: no pushed commit is inside the bundle" "0" \
  "$(git -C "$UPS/Projects/up" bundle list-heads "$UPS/.local/share/omarchy-backup/repo-sources/Projects__up.bundle" | grep -c "^$ONE ")"
HOME="$UPS" omarchy-backup baseline up >/dev/null 2>&1
assert_contains "status shows what the snapshot carries" "$(HOME="$UPS" omarchy-backup status 2>&1)" "~/Projects/up: missing commits only (2)"
assert_contains "doctor shows what the snapshot carries" "$(HOME="$UPS" omarchy-backup doctor 2>&1)" "~/Projects/up: missing commits only (2)"
UPR="$(new_home repo_up_rest)"; HOME="$UPR" omarchy-backup init >/dev/null 2>&1
mkdir -p "$UPR/.local/share/omarchy-backup/snapshots/up"; cp "$UPS/.local/share/omarchy-backup/snapshots/up"/* "$UPR/.local/share/omarchy-backup/snapshots/up/"
up_out="$(HOME="$UPR" omarchy-backup restore up --accept-unverified --yes 2>&1)"
assert_contains "the clone path is used when the remote works" "$up_out" "clone $UP_BARE -> ~/Projects/up"
assert_eq "unpushed commits come back on the clone path" "$(git -C "$UPS/Projects/up" rev-parse main)" "$(git -C "$UPR/Projects/up" rev-parse HEAD 2>/dev/null)"
assert_eq "the branch stays checked out (not detached)" "main" "$(git -C "$UPR/Projects/up" symbolic-ref --short HEAD 2>/dev/null)"
assert_eq "an unpublished branch comes back on the clone path" "$(git -C "$UPS/Projects/up" rev-parse side)" "$(git -C "$UPR/Projects/up" rev-parse side 2>/dev/null)"
assert_contains "a local-only tag comes back on the clone path" "$(git -C "$UPR/Projects/up" tag 2>/dev/null)" "local-tag"
assert_eq "a local-only lightweight tag on a pushed commit comes back" "$ONE" "$(git -C "$UPR/Projects/up" rev-parse -q --verify pushed-light 2>/dev/null)"
assert_eq "a local-only annotated tag on a pushed commit comes back" "$ONE" "$(git -C "$UPR/Projects/up" rev-parse -q --verify 'pushed-annotated^{commit}' 2>/dev/null)"
assert_eq "a local-only branch on a pushed commit comes back" "$ONE" "$(git -C "$UPR/Projects/up" rev-parse -q --verify refs/heads/at-pushed 2>/dev/null)"
assert_eq "no helper refs are left behind" "" "$(git -C "$UPR/Projects/up" for-each-ref refs/ob-snapshot 2>/dev/null)"
assert_eq "origin is the real remote" "$UP_BARE" "$(git -C "$UPR/Projects/up" remote get-url origin 2>/dev/null)"
# Detached HEAD with a commit no ref reaches: the bundle must be refreshed.
$G -C "$UPS/Projects/up" checkout -q --detach; echo d >> "$UPS/Projects/up/f"; $G -C "$UPS/Projects/up" commit -q -am detached
DET="$(git -C "$UPS/Projects/up" rev-parse HEAD)"
echo "repo ~/Projects/up full" > "$UPS/.config/omarchy-backup/paths.d/r.conf"
HOME="$UPS" omarchy-backup snapshot up-det >/dev/null 2>&1
DETR="$(new_home repo_det_rest)"; HOME="$DETR" omarchy-backup init >/dev/null 2>&1
mkdir -p "$DETR/.local/share/omarchy-backup/snapshots/up-det"; cp "$UPS/.local/share/omarchy-backup/snapshots/up-det"/* "$DETR/.local/share/omarchy-backup/snapshots/up-det/"
HOME="$DETR" omarchy-backup restore up-det --accept-unverified --yes --repos-from-snapshot >/dev/null 2>&1
assert_eq "a detached-HEAD commit is in the refreshed bundle" "$DET" "$(git -C "$DETR/Projects/up" rev-parse HEAD 2>/dev/null)"
assert_file "the detached restore has a working tree" "$DETR/Projects/up/f"
# Detached exactly at a branch tip: the restore must still fill the working tree.
TIP="$(new_home repo_tip_src)"; HOME="$TIP" omarchy-backup init >/dev/null 2>&1
git init -q -b main "$TIP/Projects/tip"; echo t > "$TIP/Projects/tip/t"; $G -C "$TIP/Projects/tip" add -A; $G -C "$TIP/Projects/tip" commit -q -m t
$G -C "$TIP/Projects/tip" tag v1; $G -C "$TIP/Projects/tip" checkout -q v1
echo "repo ~/Projects/tip" > "$TIP/.config/omarchy-backup/paths.d/r.conf"
HOME="$TIP" omarchy-backup snapshot tip >/dev/null 2>&1
TIPR="$(new_home repo_tip_rest)"; HOME="$TIPR" omarchy-backup init >/dev/null 2>&1
mkdir -p "$TIPR/.local/share/omarchy-backup/snapshots/tip"; cp "$TIP/.local/share/omarchy-backup/snapshots/tip"/* "$TIPR/.local/share/omarchy-backup/snapshots/tip/"
HOME="$TIPR" omarchy-backup restore tip --accept-unverified --yes >/dev/null 2>&1
assert_file "detached at a branch tip: working tree restored" "$TIPR/Projects/tip/t"
assert_eq "detached at a branch tip: nothing shows as deleted" "" "$(git -C "$TIPR/Projects/tip" status --porcelain 2>/dev/null)"
# History with an object git fsck rejects (bad timezone) is still imported.
FS="$(new_home repo_fsck_src)"; HOME="$FS" omarchy-backup init >/dev/null 2>&1
git init -q -b main "$FS/Projects/old"; echo o > "$FS/Projects/old/o"; git -C "$FS/Projects/old" add -A
TREE="$(git -C "$FS/Projects/old" write-tree)"
BADC="$(printf 'tree %s\nauthor t <t@t> 1000000000 +99999\ncommitter t <t@t> 1000000000 +99999\n\nold tool\n' "$TREE" | git -C "$FS/Projects/old" hash-object -t commit -w --literally --stdin)"
git -C "$FS/Projects/old" update-ref refs/heads/main "$BADC"
echo "repo ~/Projects/old" > "$FS/.config/omarchy-backup/paths.d/r.conf"
HOME="$FS" omarchy-backup snapshot old >/dev/null 2>&1
FSR="$(new_home repo_fsck_rest)"; HOME="$FSR" omarchy-backup init >/dev/null 2>&1
mkdir -p "$FSR/.local/share/omarchy-backup/snapshots/old"; cp "$FS/.local/share/omarchy-backup/snapshots/old"/* "$FSR/.local/share/omarchy-backup/snapshots/old/"
fs_out="$(HOME="$FSR" omarchy-backup restore old --accept-unverified --yes 2>&1)"
assert_eq "history git fsck objects to is still restored" "$BADC" "$(git -C "$FSR/Projects/old" rev-parse HEAD 2>/dev/null)"
assert_contains "the unchecked import is reported" "$fs_out" "imported without that check"
# Recorded branch exists only in the bundle: checked out as a branch, not detached.
$G -C "$UPS/Projects/up" checkout -q -b only-local main
echo ol > "$UPS/Projects/up/ol"; $G -C "$UPS/Projects/up" add -A; $G -C "$UPS/Projects/up" commit -q -m only-local
sed -i '/exclude \*.bundle/d' "$UPS/.config/omarchy-backup/paths.d/r.conf"
HOME="$UPS" omarchy-backup snapshot up-ol >/dev/null 2>&1
OLR="$(new_home repo_ol_rest)"; HOME="$OLR" omarchy-backup init >/dev/null 2>&1
mkdir -p "$OLR/.local/share/omarchy-backup/snapshots/up-ol"; cp "$UPS/.local/share/omarchy-backup/snapshots/up-ol"/* "$OLR/.local/share/omarchy-backup/snapshots/up-ol/"
ol_out="$(HOME="$OLR" omarchy-backup restore up-ol --accept-unverified --yes 2>&1)"
assert_eq "a branch only the bundle has is checked out as that branch" "only-local" "$(git -C "$OLR/Projects/up" symbolic-ref --short HEAD 2>/dev/null)"
assert_not_contains "no misleading 'branch not found' note" "$ol_out" "branch 'only-local' not found"
# A corrupt bundle falls back to the file-only copy.
COR="$(new_home repo_corrupt)"; HOME="$COR" omarchy-backup init >/dev/null 2>&1
mkdir -p "$COR/.local/share/omarchy-backup/snapshots/up"; cp "$UPS/.local/share/omarchy-backup/snapshots/up"/* "$COR/.local/share/omarchy-backup/snapshots/up/"
mkdir -p "$COR/.local/share/omarchy-backup/repo-sources"
# The manifest points at a junk file the payload does not overwrite.
jq '.repos[0].history_bundle=".local/share/omarchy-backup/repo-sources/junk.bundle" | .repos[0].history_bundle_kind="full"' \
  "$UPS/.local/share/omarchy-backup/snapshots/up/manifest.json" > "$COR/.local/share/omarchy-backup/snapshots/up/manifest.json"
echo "not a bundle" > "$COR/.local/share/omarchy-backup/repo-sources/junk.bundle"
c_out="$(HOME="$COR" omarchy-backup restore up --accept-unverified --yes --repos-from-snapshot 2>&1)"
assert_contains "a corrupt bundle is reported" "$c_out" "history bundle could not be read"
assert_file "a corrupt bundle falls back to the file-only copy" "$COR/Projects/up/f"
# `exclude *.bundle` keeps history out, and the manifest says so.
echo "exclude *.bundle" >> "$UPS/.config/omarchy-backup/paths.d/r.conf"
HOME="$UPS" omarchy-backup snapshot up-nob >/dev/null 2>&1
assert_eq "an excluded bundle is not advertised in the manifest" "" "$(jq -r '.repos[0].history_bundle' "$UPS/.local/share/omarchy-backup/snapshots/up-nob/manifest.json")"
assert_eq "an excluded bundle is not in the payload" "0" "$(zstd -q -d -c "$UPS/.local/share/omarchy-backup/snapshots/up-nob/payload.tar.zst" | tar -t | grep -c '\.bundle$')"
# Delta lifecycle: written while something is unpushed, byte-identical when
# unchanged, gone once everything is pushed; useless without the remote.
ST_BARE="$WORK/st-upstream.git"; git init -q --bare -b main "$ST_BARE"
STH="$(new_home repo_st_src)"; HOME="$STH" omarchy-backup init >/dev/null 2>&1
git clone -q "$ST_BARE" "$STH/Projects/st" 2>/dev/null
echo a > "$STH/Projects/st/a"; $G -C "$STH/Projects/st" add -A; $G -C "$STH/Projects/st" commit -q -m a; git -C "$STH/Projects/st" push -q origin main 2>/dev/null
echo b >> "$STH/Projects/st/a"; $G -C "$STH/Projects/st" commit -q -am b
echo "repo ~/Projects/st" > "$STH/.config/omarchy-backup/paths.d/r.conf"
STB="$STH/.local/share/omarchy-backup/repo-sources/Projects__st.bundle"
HOME="$STH" omarchy-backup snapshot st1 >/dev/null 2>&1
assert_file "delta bundle exists while a commit is unpushed" "$STB"
STB1="$(sha256sum < "$STB")"
HOME="$STH" omarchy-backup snapshot st1b >/dev/null 2>&1
assert_eq "an unchanged delta bundle stays byte-identical" "$STB1" "$(sha256sum < "$STB")"
STDEAD="$(new_home repo_st_dead)"; HOME="$STDEAD" omarchy-backup init >/dev/null 2>&1
mkdir -p "$STDEAD/.local/share/omarchy-backup/snapshots/st1"; cp "$STH/.local/share/omarchy-backup/snapshots/st1"/* "$STDEAD/.local/share/omarchy-backup/snapshots/st1/"
jq --arg r "$WORK/gone.git" '.repos[0].remote=$r' "$STH/.local/share/omarchy-backup/snapshots/st1/manifest.json" > "$STDEAD/.local/share/omarchy-backup/snapshots/st1/manifest.json"
std_out="$(HOME="$STDEAD" omarchy-backup restore st1 --accept-unverified --yes 2>&1)"
assert_contains "delta without the remote: says why only files come back" "$std_out" "only holds the commits its remote lacked"
assert_contains "delta without the remote: points at \`full\`" "$std_out" "repo ~/Projects/st full"
assert_file "delta without the remote: the files come back" "$STDEAD/Projects/st/a"
assert_not_file "delta without the remote: no half-built repo" "$STDEAD/Projects/st/.git"
git -C "$STH/Projects/st" push -q origin main 2>/dev/null
HOME="$STH" omarchy-backup snapshot st2 >/dev/null 2>&1
assert_not_file "everything pushed: the stale delta bundle is removed" "$STB"
assert_eq "everything pushed: manifest has no bundle" "" "$(jq -r '.repos[0].history_bundle_kind' "$STH/.local/share/omarchy-backup/snapshots/st2/manifest.json")"
assert_contains "everything pushed: doctor says metadata only" "$(HOME="$STH" omarchy-backup doctor 2>&1)" "~/Projects/st: metadata only"
# Globs with spaces; nested repos are not covered by the outer declaration.
SP="$(new_home repo_spaces)"; HOME="$SP" omarchy-backup init >/dev/null 2>&1
mkdir -p "$SP/My Work/app/vendor/lib"
git init -q -b main "$SP/My Work/app"; echo a > "$SP/My Work/app/a"; $G -C "$SP/My Work/app" add a; $G -C "$SP/My Work/app" commit -q -m a
git init -q -b main "$SP/My Work/app/vendor/lib"; echo l > "$SP/My Work/app/vendor/lib/l"; $G -C "$SP/My Work/app/vendor/lib" add -A; $G -C "$SP/My Work/app/vendor/lib" commit -q -m l
SP_BARE="$WORK/sp-upstream.git"; git init -q --bare -b main "$SP_BARE"
git -C "$SP/My Work/app" remote add origin "$SP_BARE"; git -C "$SP/My Work/app" push -q origin main 2>/dev/null
printf 'repo ~/My Work/*\n' > "$SP/.config/omarchy-backup/paths.d/r.conf"
assert_contains "glob without \`full\`, pushed repo: metadata only" "$(HOME="$SP" omarchy-backup doctor 2>&1)" "~/My Work/app: metadata only"
printf 'repo ~/My Work/* full\n' > "$SP/.config/omarchy-backup/paths.d/r.conf"
printf 'OB_CFG_REPO_SCAN_ROOTS="~/Projects"\n' >> "$SP/.config/omarchy-backup/config.conf"
echo "include ~/My Work" >> "$SP/.config/omarchy-backup/paths.d/r.conf"
sp_doc="$(HOME="$SP" omarchy-backup doctor 2>&1)"
assert_contains "a glob with spaces declares the repo" "$sp_doc" "$(printf '%-28s %s' 'Own git checkouts' 'OK')"
assert_contains "\`full\` works with a glob and spaces" "$sp_doc" "~/My Work/app: full history (repo ... full)"
HOME="$SP" omarchy-backup snapshot spfull >/dev/null 2>&1
assert_eq "\`full\` via glob: full bundle in the manifest" "full" "$(jq -r '.repos[] | select(.path=="My Work/app") | .history_bundle_kind' "$SP/.local/share/omarchy-backup/snapshots/spfull/manifest.json")"
assert_not_contains "the glob-declared repo is not flagged" "$sp_doc" "~/My Work/app (no remote"
assert_contains "a nested repo is flagged although its parent is declared" "$sp_doc" "~/My Work/app/vendor/lib (no remote; files backed up, history not)"

echo "== a repo with a huge uncommitted diff (argument size limit) =="
BIGH="$(new_home repo_bigdiff)"; HOME="$BIGH" omarchy-backup init >/dev/null 2>&1
git init -q -b main "$BIGH/Projects/big"; seq 1 40000 > "$BIGH/Projects/big/data.txt"
$G -C "$BIGH/Projects/big" add -A; $G -C "$BIGH/Projects/big" commit -q -m big
seq 1 40000 | sed 's/$/ changed/' > "$BIGH/Projects/big/data.txt"
echo "repo ~/Projects/big" > "$BIGH/.config/omarchy-backup/paths.d/r.conf"
big_rc=0; HOME="$BIGH" omarchy-backup snapshot big >/dev/null 2>&1 || big_rc=$?
assert_eq "a snapshot with a >200 KB diff succeeds" "0" "$big_rc"
assert_eq "the whole diff is in the manifest" "true" \
  "$(jq '.repos[0].diff | length > 200000' "$BIGH/.local/share/omarchy-backup/snapshots/big/manifest.json" 2>/dev/null)"
assert_contains "status works with a huge diff" "$(HOME="$BIGH" omarchy-backup status 2>&1)" "Status:"

echo "== import: a snapshot folder obtained without rclone =="
DL="$WORK/downloaded/withrepo"; mkdir -p "$DL"; cp "$RSNAP"/* "$DL/"
IMP="$(new_home repo_import)"; HOME="$IMP" omarchy-backup init >/dev/null 2>&1
i_out="$(HOME="$IMP" omarchy-backup import "$DL" --accept-unverified 2>&1)"
assert_contains "import names the next step" "$i_out" "omarchy-backup restore withrepo --dry-run"
assert_eq "imported snapshot is listed in state" "withrepo" "$(jq -r '.snapshots[0].name' "$IMP/.local/share/omarchy-backup/state.json")"
HOME="$IMP" omarchy-backup restore withrepo --accept-unverified --yes --repos-from-snapshot >/dev/null 2>&1
assert_file "imported snapshot restores" "$IMP/Projects/tool/bin/tool"
i2_rc=0; HOME="$IMP" omarchy-backup import "$DL" --accept-unverified >/dev/null 2>&1 || i2_rc=$?
assert_eq "importing the same snapshot twice is refused" "1" "$i2_rc"
BAD="$WORK/downloaded/bad"; mkdir -p "$BAD"; cp "$RSNAP"/* "$BAD/"; jq '.name="badcopy"' "$RSNAP/manifest.json" > "$BAD/manifest.json"
printf 'x' >> "$BAD/payload.tar.zst"
IMP2="$(new_home repo_import_bad)"; HOME="$IMP2" omarchy-backup init >/dev/null 2>&1
b2_out="$(HOME="$IMP2" omarchy-backup import "$BAD" --accept-unverified 2>&1)"
assert_contains "a corrupt download is refused" "$b2_out" "checksum mismatch"
assert_not_file "nothing is imported from a corrupt download" "$IMP2/.local/share/omarchy-backup/snapshots/badcopy"

echo "== doctor does not require a particular agent vendor =="
HOME="$(new_home home_other_agents)"
omarchy-backup init >/dev/null 2>&1
mkdir -p "$HOME/.config/opencode" "$HOME/shared"
echo "# rules" > "$HOME/shared/AGENTS.md"
ln -s "$HOME/shared/AGENTS.md" "$HOME/.config/opencode/AGENTS.md"
ag_out="$(omarchy-backup doctor 2>&1)"
assert_contains "no Claude/Codex/Gemini: agent configuration OK" "$ag_out" "$(printf '%-28s %s' 'Agent configuration' 'OK')"
assert_contains "no Claude: machine memory OK" "$ag_out" "$(printf '%-28s %s' 'Machine memory' 'OK')"
rm "$HOME/shared/AGENTS.md"
ag2_out="$(omarchy-backup doctor 2>&1)"
assert_contains "a broken shared instruction link is flagged" "$ag2_out" "broken symlink: $HOME/.config/opencode/AGENTS.md"

echo "== recovery notes are uploaded next to the snapshots =="
HOME="$(new_home home_recovery_notes)"
omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" recovery-notes
seed_workspace "$HOME"
echo "# How to get back up" > "$HOME/notes.md"
omarchy-backup config set OB_CFG_RECOVERY_NOTES "~/notes.md" >/dev/null 2>&1
omarchy-backup snapshot rn-base --baseline >/dev/null 2>&1
rn_out="$(omarchy-backup push rn-base 2>&1)"
assert_contains "push reports the uploaded notes" "$rn_out" "Recovery notes uploaded"
assert_eq "RECOVERY.md lies next to the snapshots" "# How to get back up" \
  "$(cat "$REMOTE_STORAGE/recovery-notes/$(hostname)/RECOVERY.md" 2>/dev/null)"
TOOLARC="$REMOTE_STORAGE/recovery-notes/$(hostname)/omarchy-backup-tool.tar.gz"
assert_file "a copy of the tool lies next to the snapshots" "$TOOLARC"
assert_contains "the tool copy contains the CLI" "$(tar -tzf "$TOOLARC")" "omarchy-backup/bin/omarchy-backup"
assert_not_contains "the tool copy contains no .git" "$(tar -tzf "$TOOLARC")" "/.git/"
TX="$WORK/toolx"; mkdir -p "$TX"; tar -xzf "$TOOLARC" -C "$TX"
assert_contains "the unpacked tool copy runs" "$(HOME="$WORK/toolx-home" "$TX/omarchy-backup/bin/omarchy-backup" help 2>&1)" "omarchy-backup import"

echo
echo "== app launchers and mise tools are captured; restore names mise install =="
APPS_HOME="$(new_home home_apps)"
HOME="$APPS_HOME" omarchy-backup init >/dev/null 2>&1
mkdir -p "$APPS_HOME/.local/share/applications" "$APPS_HOME/.config/mise"
printf '[Desktop Entry]\nName=Mail\nExec=true\n' > "$APPS_HOME/.local/share/applications/Mail.desktop"
printf 'old\n' > "$APPS_HOME/.local/share/applications/Mail.desktop.bak.1"
printf 'x\n' > "$APPS_HOME/.local/share/applications/mimeinfo.cache"
printf '[tools]\ngh = "latest"\n' > "$APPS_HOME/.config/mise/config.toml"
HOME="$APPS_HOME" omarchy-backup snapshot --baseline apps >/dev/null 2>&1
apps_list="$(tar --zstd -tf "$APPS_HOME/.local/share/omarchy-backup/snapshots/apps/payload.tar.zst" 2>/dev/null)"
assert_contains "launcher is in the payload" "$apps_list" ".local/share/applications/Mail.desktop"
assert_contains "mise config is in the payload" "$apps_list" ".config/mise/config.toml"
assert_not_contains "launcher backups are excluded" "$apps_list" "Mail.desktop.bak.1"
assert_not_contains "mimeinfo.cache is excluded" "$apps_list" "mimeinfo.cache"
APPS_FRESH="$(new_home home_apps_fresh)"
HOME="$APPS_FRESH" omarchy-backup init >/dev/null 2>&1
mkdir -p "$APPS_FRESH/.local/share/omarchy-backup/snapshots"
cp -r "$APPS_HOME/.local/share/omarchy-backup/snapshots/apps" "$APPS_FRESH/.local/share/omarchy-backup/snapshots/apps"
apps_out="$(HOME="$APPS_FRESH" PATH="$STUB_BIN:$PATH" omarchy-backup restore apps --dry-run 2>&1)"
assert_contains "restore names mise install" "$apps_out" "mise install"

echo "== never trust the destination: integrity ledger =="
NOTIFY_BIN="$WORK/notify-bin"; mkdir -p "$NOTIFY_BIN"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/notify.log"\n' "$WORK" > "$NOTIFY_BIN/notify-send"; chmod +x "$NOTIFY_BIN/notify-send"
HOME="$(new_home home_integrity)"; omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" integrity
seed_workspace "$HOME"
omarchy-backup snapshot i-base --baseline >/dev/null 2>&1
omarchy-backup push i-base >/dev/null 2>&1
LEDGER="$HOME/.local/share/omarchy-backup/integrity-ledger.json"
assert_eq "push records the backend's md5 of the payload" "$(md5sum < "$HOME/.local/share/omarchy-backup/snapshots/i-base/payload.tar.zst" | awk '{print $1}')" \
  "$(jq -r '.snapshots["i-base"].files["payload.tar.zst"].md5' "$LEDGER")"
assert_not_contains "the ledger is not part of any snapshot" "$(zstd -q -d -c "$HOME/.local/share/omarchy-backup/snapshots/i-base/payload.tar.zst" | tar -t)" "integrity-ledger"
ic_rc=0; omarchy-backup integrity check >/dev/null 2>&1 || ic_rc=$?
assert_eq "untouched destination passes the integrity check" "0" "$ic_rc"
# Attacker: new payload AND a recomputed manifest checksum.
IR="$REMOTE_STORAGE/integrity/$(hostname)/i-base"
printf 'evil' >> "$IR/payload.tar.zst"
jq --arg s "$(sha256sum < "$IR/payload.tar.zst" | awk '{print $1}')" '.payload.sha256=$s' "$IR/manifest.json" > "$WORK/m.json" && cp "$WORK/m.json" "$IR/manifest.json"
mkdir -p "$REMOTE_STORAGE/integrity/$(hostname)/planted"; echo x > "$REMOTE_STORAGE/integrity/$(hostname)/planted/manifest.json"
i_doc="$(omarchy-backup doctor 2>&1)"
assert_contains "doctor fails on a tampered destination" "$i_doc" "$(printf '%-28s %s' 'Destination integrity' 'FAIL')"
assert_contains "doctor names the replaced payload" "$i_doc" "changed: i-base/payload.tar.zst"
assert_contains "doctor names the recomputed manifest" "$i_doc" "changed: i-base/manifest.json"
assert_contains "doctor names a planted folder" "$i_doc" "added: planted/ (unknown folder)"
assert_contains "status goes red after the check" "$(omarchy-backup status 2>&1 | head -n 1)" "Status: RED"
assert_contains "status says why" "$(omarchy-backup status 2>&1)" "backup destination modified: changed: i-base/payload.tar.zst"
rm -f "$WORK/notify.log"
echo "drift = 1" >> "$HOME/.config/hypr/looknfeel.lua"
PATH="$NOTIFY_BIN:$PATH" omarchy-backup snapshot i-auto --auto >/dev/null 2>&1
assert_contains "the automatic run raises a critical alert" "$(cat "$WORK/notify.log" 2>/dev/null)" "-u critical"
assert_contains "the alert says what happened" "$(cat "$WORK/notify.log" 2>/dev/null)" "backup destination was modified"
PATH="$NOTIFY_BIN:$PATH" omarchy-backup snapshot i-auto2 --auto >/dev/null 2>&1
assert_eq "an unchanged set of problems does not alert again" "1" "$(grep -c 'backup destination was modified' "$WORK/notify.log")"
ib_out="$(omarchy-backup push i-auto 2>&1)"; ib_rc=$?
assert_contains "no upload to a destination with unresolved problems" "$ib_out" "refusing to upload"
assert_eq "the refused push fails" "1" "$ib_rc"
assert_contains "the tampering is not adopted by later runs" "$(omarchy-backup doctor 2>&1)" "changed: i-base/payload.tar.zst"
ipe_out="$(omarchy-backup pull i-base --accept-unverified 2>&1)"
assert_contains "pull never replaces an existing local snapshot" "$ipe_out" "already exists"
assert_file "the existing local snapshot is kept" "$HOME/.local/share/omarchy-backup/snapshots/i-base/payload.tar.zst"
rm -rf "$HOME/.local/share/omarchy-backup/snapshots/i-base"
ip_out="$(omarchy-backup pull i-base --accept-unverified 2>&1)"
assert_contains "pull refuses content that differs from the upload" "$ip_out" "differs from what this machine uploaded"
assert_not_file "nothing tampered is kept after pull" "$HOME/.local/share/omarchy-backup/snapshots/i-base/payload.tar.zst"
assert_eq "no staging folder is left behind" "" "$(ls -A "$HOME/.local/share/omarchy-backup/snapshots" | grep '\.pull\.' || true)"
# Resolving: delete what is not ours, forget the deleted snapshot.
rm -rf "$REMOTE_STORAGE/integrity/$(hostname)/planted" "$IR"
omarchy-backup integrity forget i-base >/dev/null 2>&1
ir_rc=0; omarchy-backup integrity check >/dev/null 2>&1 || ir_rc=$?
assert_eq "after cleanup and forget the destination is consistent again" "0" "$ir_rc"
assert_contains "uploads work again after the cleanup" "$(omarchy-backup push i-auto 2>&1)" "Upload complete and verified"
# Pre-planted folder with the name of the next upload: only our files count.
HOME="$(new_home home_preplant)"; omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" preplant
seed_workspace "$HOME"
omarchy-backup snapshot pp-1 >/dev/null 2>&1
mkdir -p "$REMOTE_STORAGE/preplant/$(hostname)/pp-1"; echo evil > "$REMOTE_STORAGE/preplant/$(hostname)/pp-1/run-me.sh"
omarchy-backup push pp-1 >/dev/null 2>&1
assert_contains "a file planted before the upload stays a problem" "$(omarchy-backup integrity check 2>&1)" "added: pp-1/run-me.sh"
echo evil > "$REMOTE_STORAGE/preplant/$(hostname)/notes.txt"
assert_contains "a file planted next to index.json is a problem" "$(omarchy-backup integrity check 2>&1)" "added: notes.txt"
# Mounted cloud folder: only size + date without downloading (weak).
HOME="$(new_home home_integrity_weak)"; omarchy-backup init >/dev/null 2>&1
WEAKD="$WORK/weak-dest"; mkdir -p "$WEAKD"
omarchy-backup config set OB_CFG_REMOTE_PATH "$WEAKD" >/dev/null 2>&1
seed_workspace "$HOME"
omarchy-backup snapshot w-base >/dev/null 2>&1
TZ=Europe/Berlin OMARCHY_BACKUP_TEST_WEAK_INTEGRITY=true omarchy-backup push w-base >/dev/null 2>&1
wtz_rc=0; TZ=America/New_York OMARCHY_BACKUP_TEST_WEAK_INTEGRITY=true omarchy-backup integrity check >/dev/null 2>&1 || wtz_rc=$?
assert_eq "a time zone change is no change (weak mode)" "0" "$wtz_rc"
assert_not_contains "without test mode the weak hook is ignored" \
  "$(OMARCHY_BACKUP_TEST_MODE=false OMARCHY_BACKUP_TEST_WEAK_INTEGRITY=true omarchy-backup doctor 2>&1)" "only by size and date"
w_doc="$(OMARCHY_BACKUP_TEST_WEAK_INTEGRITY=true omarchy-backup doctor 2>&1)"
assert_contains "doctor says when only a weak check is possible" "$w_doc" "only by size and date"
assert_contains "doctor names the way to a strong check" "$w_doc" "OB_CFG_INTEGRITY_RCLONE_REMOTE"
printf 'x' >> "$WEAKD/$(hostname)/w-base/payload.tar.zst"
w_doc="$(OMARCHY_BACKUP_TEST_WEAK_INTEGRITY=true omarchy-backup doctor 2>&1)"
assert_contains "the weak check still catches a changed size" "$w_doc" "changed: w-base/payload.tar.zst"
# An upload from before the ledger existed (local slot already rotated away,
# but listed in the remote index) is "unrecorded", not an unknown folder.
WL="$HOME/.local/share/omarchy-backup/integrity-ledger.json"
jq --argjson later "$(( $(date +%s) + 3600 ))" '.snapshots = {} | .base = null | .created_epoch = $later' "$WL" > "$WORK/wl.json" && cp "$WORK/wl.json" "$WL"
jq '.snapshots = []' "$HOME/.local/share/omarchy-backup/state.json" > "$WORK/ws.json" && cp "$WORK/ws.json" "$HOME/.local/share/omarchy-backup/state.json"
wu_out="$(OMARCHY_BACKUP_TEST_WEAK_INTEGRITY=true omarchy-backup integrity check 2>&1)"
assert_contains "an indexed pre-ledger upload is offered for adoption" "$wu_out" "integrity record w-base"
assert_not_contains "an indexed pre-ledger upload is not an unknown folder" "$wu_out" "unknown folder"

echo "== never trust the destination: signatures =="
GHAPI="$WORK/ghapi"; mkdir -p "$GHAPI/users/testsigner" "$GHAPI/users/other"
export OMARCHY_BACKUP_GITHUB_API="file://$GHAPI"
HOME="$(new_home home_sign)"; omarchy-backup init >/dev/null 2>&1
seed_workspace "$HOME"
SKEY="$HOME/.config/omarchy-backup/backup-ident"
ssh-keygen -q -t ed25519 -N '' -C test -f "$SKEY"; chmod 600 "$SKEY"
ssh-keygen -q -t ed25519 -N '' -C other -f "$WORK/other-key"
jq -n --arg k "$(cat "$SKEY.pub")" '[{id:1, key:$k, title:"backup"}]' > "$GHAPI/users/testsigner/ssh_signing_keys"
jq -n --arg k "$(cat "$WORK/other-key.pub")" '[{id:2, key:$k, title:"x"}]' > "$GHAPI/users/other/ssh_signing_keys"
s_doc="$(omarchy-backup doctor 2>&1)"
assert_contains "doctor warns when nothing is signed" "$s_doc" "no signing key configured"
omarchy-backup snapshot unsigned1 >/dev/null 2>&1
echo "include ~/.config/omarchy-backup" > "$HOME/.config/omarchy-backup/paths.d/self.conf"
omarchy-backup config set OB_CFG_SIGNING_KEY "~/.config/omarchy-backup/backup-ident" >/dev/null 2>&1
omarchy-backup config set OB_CFG_SIGNER_GITHUB testsigner >/dev/null 2>&1
assert_contains "doctor accepts a key the trust anchor knows" "$(omarchy-backup doctor 2>&1)" "$(printf '%-28s %s' 'Snapshot signatures' 'OK')"
omarchy-backup snapshot signed1 >/dev/null 2>&1
SDIR="$HOME/.local/share/omarchy-backup/snapshots/signed1"
assert_file "snapshot manifest is signed" "$SDIR/manifest.json.sig"
assert_eq "the signing key never enters the payload (only its .pub)" "0" "$(zstd -q -d -c "$SDIR/payload.tar.zst" | tar -t | grep -c 'backup-ident$')"
assert_not_contains "the signing key is not in the checksums" "$(cat "$SDIR/checksums.sha256")" "backup-ident "
assert_contains "the rest of the tool's config is still backed up" "$(zstd -q -d -c "$SDIR/payload.tar.zst" | tar -t)" ".config/omarchy-backup/config.conf"
omarchy-backup config set OB_CFG_SIGNER_GITHUB other >/dev/null 2>&1
assert_contains "doctor warns when the anchor does not know the key" "$(omarchy-backup doctor 2>&1)" "not among the keys"
omarchy-backup config set OB_CFG_SIGNER_GITHUB testsigner >/dev/null 2>&1
# A fresh machine: trust comes from the command line, never the snapshot.
sign_into() {  # <home> <snapshot> -> copies the snapshot into a fresh home
  local h; h="$(new_home "$1")"; HOME="$h" omarchy-backup init >/dev/null 2>&1
  mkdir -p "$h/.local/share/omarchy-backup/snapshots/$2"; cp "$HOME/.local/share/omarchy-backup/snapshots/$2"/* "$h/.local/share/omarchy-backup/snapshots/$2/"
  echo "$h"
}
SV="$(sign_into sig_ok signed1)"
sv_out="$(HOME="$SV" omarchy-backup restore signed1 --dry-run --signer-github testsigner 2>&1)"
assert_contains "a genuine snapshot verifies and names the key" "$sv_out" "Signature OK: ED25519 key SHA256:"
assert_contains "the trust anchor is named" "$sv_out" "GitHub signing keys of 'testsigner'"
ST="$(sign_into sig_tampered signed1)"
STD="$ST/.local/share/omarchy-backup/snapshots/signed1"
printf 'evil' >> "$STD/payload.tar.zst"
jq --arg s "$(sha256sum < "$STD/payload.tar.zst" | awk '{print $1}')" '.payload.sha256=$s' "$STD/manifest.json" > "$WORK/m2.json" && cp "$WORK/m2.json" "$STD/manifest.json"
st_rc=0; st_out="$(HOME="$ST" omarchy-backup restore signed1 --signer-github testsigner --yes < /dev/null 2>&1)" || st_rc=$?
assert_contains "a recomputed manifest fails the signature" "$st_out" "UNVERIFIED SNAPSHOT (invalid)"
assert_contains "the restore stops without confirmation" "$st_out" "needs your confirmation"
assert_eq "the stopped restore exits non-zero" "1" "$st_rc"
assert_not_file "nothing was written" "$ST/.local/bin/mytool"
SW="$(sign_into sig_wrong signed1)"
assert_contains "an unknown signer is not trusted" "$(HOME="$SW" omarchy-backup restore signed1 --signer-github other --yes < /dev/null 2>&1)" "UNVERIFIED SNAPSHOT (invalid)"
SU="$(sign_into sig_unsigned unsigned1)"
su_out="$(HOME="$SU" omarchy-backup restore unsigned1 --signer-github testsigner --yes < /dev/null 2>&1)"
assert_contains "an unsigned snapshot is reported" "$su_out" "UNVERIFIED SNAPSHOT (unsigned)"
assert_not_file "an unsigned snapshot is not restored silently" "$SU/.local/bin/mytool"
HOME="$SU" omarchy-backup restore unsigned1 --accept-unverified --yes < /dev/null >/dev/null 2>&1
assert_file "--accept-unverified lets the user decide" "$SU/.local/bin/mytool"
SA="$(sign_into sig_allowed signed1)"
cp "$SKEY.pub" "$WORK/allowed.pub"
assert_contains "a local allowed-signers file works as anchor" "$(HOME="$SA" omarchy-backup restore signed1 --dry-run --allowed-signers "$WORK/allowed.pub" 2>&1)" "Signature OK"
SN="$(sign_into sig_noanchor signed1)"
assert_contains "without any anchor nothing counts as verified" "$(HOME="$SN" omarchy-backup restore signed1 --dry-run 2>&1)" "UNVERIFIED SNAPSHOT (no-anchor)"
SI="$WORK/sig-import-src"; mkdir -p "$SI"; cp "$STD"/* "$SI/"
SIH="$(new_home sig_import)"; HOME="$SIH" omarchy-backup init >/dev/null 2>&1
si_out="$(HOME="$SIH" omarchy-backup import "$SI" --signer-github testsigner < /dev/null 2>&1)"
assert_contains "import checks the signature too" "$si_out" "UNVERIFIED SNAPSHOT (invalid)"
assert_not_file "a refused import copies nothing" "$SIH/.local/share/omarchy-backup/snapshots/signed1"

echo "== never trust the destination: restore review =="
RV="$(sign_into review_new signed1)"
rv_out="$(HOME="$RV" omarchy-backup restore signed1 --signer-github testsigner < /dev/null 2>&1)"; rv_rc=$?
assert_contains "restore lists what would be written" "$rv_out" "NEW  ~/.local/bin/mytool"
assert_contains "a new file is shown with its content" "$rv_out" "| echo hi"
assert_contains "the review groups per folder" "$rv_out" "new    0 changed  ~/.local/bin"
assert_contains "agent instructions count as security-relevant" "$rv_out" "~/.claude/projects/testproj/memory"
assert_contains "without --yes a non-interactive restore stops" "$rv_out" "Stopped before writing anything"
assert_eq "the stopped review exits non-zero" "1" "$rv_rc"
assert_not_file "the review stops before any write" "$RV/.local/bin/mytool"
RC="$(sign_into review_changed signed1)"
mkdir -p "$RC/.local/bin"; printf '#!/bin/bash\necho mine\n' > "$RC/.local/bin/mytool"
rc_out="$(HOME="$RC" omarchy-backup restore signed1 --dry-run --signer-github testsigner 2>&1)"
assert_contains "a differing file is marked CHANGED" "$rc_out" "CHANGED  ~/.local/bin/mytool"
assert_contains "the difference is shown" "$rc_out" "-echo mine"
assert_eq "dry run leaves the file alone" "mine" "$(sed -n 2p "$RC/.local/bin/mytool" | awk '{print $2}')"
rcy_out="$(HOME="$RC" omarchy-backup restore signed1 --signer-github testsigner --yes < /dev/null 2>&1)"
assert_contains "--yes accepts the reviewed content" "$(cat "$RC/.local/bin/mytool")" "echo hi"
assert_contains "the review shows the tool's own config in full" "$rcy_out" "+OB_CFG_SIGNER_GITHUB='testsigner'"
assert_file "the snapshot's config.conf is written next to the active one" "$RC/.config/omarchy-backup/config.conf.restored"
assert_not_contains "the active config.conf is not replaced" "$(cat "$RC/.config/omarchy-backup/config.conf")" "testsigner"
assert_contains "the user is told how to adopt it" "$rcy_out" "mv ~/.config/omarchy-backup/config.conf.restored"
# The environment carries no trust decisions.
RE="$(sign_into review_env signed1)"
OB_DRY_RUN=true OB_RESTORE_YES=true HOME="$RE" omarchy-backup restore signed1 --signer-github testsigner < /dev/null >/dev/null 2>&1
assert_not_file "OB_RESTORE_YES from the environment is ignored" "$RE/.local/bin/mytool"
OB_DRY_RUN=true HOME="$RE" omarchy-backup restore signed1 --signer-github testsigner --yes < /dev/null >/dev/null 2>&1
assert_file "OB_DRY_RUN from the environment does not make a restore dry" "$RE/.local/bin/mytool"
RX="$(sign_into review_api signed1)"
assert_not_contains "without test mode the GitHub API override is ignored" \
  "$(OMARCHY_BACKUP_TEST_MODE=false https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 HOME="$RX" omarchy-backup restore signed1 --dry-run --signer-github testsigner 2>&1)" "Signature OK"
# Hostile names in the manifest never reach pacman or systemctl.
RH="$(sign_into review_hostile signed1)"
RHM="$RH/.local/share/omarchy-backup/snapshots/signed1/manifest.json"
jq '.packages.pacman_explicit += ["--overwrite=*", "a;b"] | .packages.aur_foreign += ["-Syu"]
    | .systemd_user_units += [{name:"-x.service",enabled:"enabled",active:"active"},
                              {name:"../../evil.service",enabled:"enabled",active:"inactive"},
                              {name:"ok-unit.timer",enabled:"enabled",active:"inactive"}]' "$RHM" > "$WORK/rh.json" && cp "$WORK/rh.json" "$RHM"
rh_out="$(HOME="$RH" PATH="$STUB_BIN:$PATH" omarchy-backup restore signed1 --dry-run 2>&1)"
assert_contains "an option-like package name is ignored" "$rh_out" "IGNORED  invalid package name: --overwrite=*"
assert_contains "a package name with shell characters is ignored" "$rh_out" "IGNORED  invalid package name: a;b"
assert_contains "an option-like AUR name is ignored" "$rh_out" "IGNORED  invalid package name: -Syu"
assert_contains "an option-like unit name is ignored" "$rh_out" "IGNORED  invalid unit name: -x.service"
assert_contains "a path-like unit name is ignored" "$rh_out" "IGNORED  invalid unit name: ../../evil.service"
assert_contains "valid units are listed in the review" "$rh_out" "unit     ok-unit.timer (enable)"
assert_contains "valid units are enabled with --" "$rh_out" "systemctl --user enable -- ok-unit.timer"
assert_not_contains "no hostile unit reaches systemctl" "$rh_out" "enable -- -x.service"
assert_not_contains "no hostile package reaches pacman" "$rh_out" "-- --overwrite"
# Tool copy and RECOVERY.md are signed, recorded, and verifiable by hand.
sed -i 's/^OB_CFG_REMOTE_NAME=.*/OB_CFG_REMOTE_NAME=testlocal/' "$HOME/.config/omarchy-backup/config.conf"
omarchy-backup config set OB_CFG_REMOTE_PATH "$REMOTE_STORAGE/signed-extras" >/dev/null 2>&1
mkdir -p "$REMOTE_STORAGE/signed-extras"
echo "# notes" > "$HOME/notes.md"; omarchy-backup config set OB_CFG_RECOVERY_NOTES "~/notes.md" >/dev/null 2>&1
omarchy-backup push signed1 >/dev/null 2>&1
SXB="$REMOTE_STORAGE/signed-extras/$(hostname)"
assert_file "the tool copy is signed" "$SXB/omarchy-backup-tool.tar.gz.sig"
assert_file "RECOVERY.md is signed" "$SXB/RECOVERY.md.sig"
jq -r '.[].key' "$GHAPI/users/testsigner/ssh_signing_keys" | sed 's/^/backup-signer namespaces="omarchy-backup" /' > "$WORK/allowed-readme"
assert_contains "the README recipe verifies the tool copy" \
  "$(ssh-keygen -Y verify -f "$WORK/allowed-readme" -I backup-signer -n omarchy-backup -s "$SXB/omarchy-backup-tool.tar.gz.sig" < "$SXB/omarchy-backup-tool.tar.gz" 2>&1)" "Good"
assert_contains "the README recipe verifies RECOVERY.md" \
  "$(ssh-keygen -Y verify -f "$WORK/allowed-readme" -I backup-signer -n omarchy-backup -s "$SXB/RECOVERY.md.sig" < "$SXB/RECOVERY.md" 2>&1)" "Good"
assert_eq "the ledger covers the signed tool copy" "true" \
  "$(jq '.base.files | has("omarchy-backup-tool.tar.gz") and has("omarchy-backup-tool.tar.gz.sig") and has("RECOVERY.md.sig") and has("index.json")' "$HOME/.local/share/omarchy-backup/integrity-ledger.json")"
unset OMARCHY_BACKUP_GITHUB_API

echo "== never trust the destination: recording, adoption, pending uploads, staging =="
HOME="$(new_home home_round2)"; omarchy-backup init >/dev/null 2>&1
configure_remote "$HOME" round2
seed_workspace "$HOME"
R2="$REMOTE_STORAGE/round2/$(hostname)"
omarchy-backup snapshot rc-1 >/dev/null 2>&1
REC_BIN="$WORK/rec-bin"; mkdir -p "$REC_BIN"
cat > "$REC_BIN/rclone" <<REC
#!/bin/bash
# Someone swaps the payload right after the verification.
if [ "\$1" = check ]; then "$REAL_RCLONE" "\$@"; rc=\$?; printf x >> "$R2/rc-1/payload.tar.zst"; exit \$rc; fi
exec "$REAL_RCLONE" "\$@"
REC
chmod +x "$REC_BIN/rclone"
rec_rc=0; rec_out="$(PATH="$REC_BIN:$PATH" omarchy-backup push rc-1 2>&1)" || rec_rc=$?
assert_eq "a destination that differs right after upload fails the push (retry)" "75" "$rec_rc"
assert_contains "the failed record is explained" "$rec_out" "treating it as not uploaded"
assert_eq "such an upload is not marked as pushed" "null" \
  "$(jq -r '.snapshots[] | select(.name=="rc-1") | .remote_pushed // "null"' "$HOME/.local/share/omarchy-backup/state.json")"
assert_eq "nothing unverified is recorded" "null" "$(jq -r '.snapshots["rc-1"] // "null"' "$HOME/.local/share/omarchy-backup/integrity-ledger.json" 2>/dev/null || echo null)"
assert_contains "the retry overwrites and records the upload" "$(omarchy-backup push rc-1 2>&1)" "Upload complete and verified"
# Listed as uploaded after the ledger existed, but never recorded: a problem.
sleep 1
omarchy-backup snapshot rc-2 >/dev/null 2>&1
mkdir -p "$R2/rc-2"; cp "$HOME/.local/share/omarchy-backup/snapshots/rc-2"/* "$R2/rc-2/"
jq '.snapshots |= map(if .name=="rc-2" then .remote_pushed=true else . end)' "$HOME/.local/share/omarchy-backup/state.json" > "$WORK/r2s.json" \
  && cp "$WORK/r2s.json" "$HOME/.local/share/omarchy-backup/state.json"
assert_contains "pushed after the ledger existed but unrecorded is a problem" "$(omarchy-backup integrity check 2>&1)" \
  "added: rc-2/ (listed as uploaded after the ledger existed, but never recorded)"
rm -rf "$R2/rc-2"
jq '.snapshots |= map(if .name=="rc-2" then .remote_pushed=false else . end)' "$HOME/.local/share/omarchy-backup/state.json" > "$WORK/r2s.json" \
  && cp "$WORK/r2s.json" "$HOME/.local/share/omarchy-backup/state.json"
# Adoption: only the snapshot's own files, only if they match the local copy.
L2="$HOME/.local/share/omarchy-backup/integrity-ledger.json"
jq '.snapshots |= del(.["rc-1"]) | .created_epoch = 4102444800' "$L2" > "$WORK/l2.json" && cp "$WORK/l2.json" "$L2"
echo evil > "$R2/rc-1/extra.sh"
ad_out="$(omarchy-backup integrity record rc-1 2>&1)"
assert_contains "adoption names what it leaves out" "$ad_out" "extra.sh"
assert_contains "a planted extra file stays a problem after adoption" "$(omarchy-backup integrity check 2>&1)" "added: rc-1/extra.sh"
rm -f "$R2/rc-1/extra.sh"
jq '.snapshots |= del(.["rc-1"])' "$L2" > "$WORK/l2.json" && cp "$WORK/l2.json" "$L2"
printf 'x' >> "$R2/rc-1/payload.tar.zst"
ad2_rc=0; ad2_out="$(omarchy-backup integrity record rc-1 2>&1)" || ad2_rc=$?
assert_contains "adoption refuses content that differs from the local copy" "$ad2_out" "differs from the local copy"
assert_eq "the refused adoption fails" "1" "$ad2_rc"
mv "$HOME/.local/share/omarchy-backup/snapshots/rc-1" "$WORK/rc-1-away"
ad3_rc=0; ad3_out="$(omarchy-backup integrity record rc-1 < /dev/null 2>&1)" || ad3_rc=$?
assert_contains "without a local copy adoption says what it would trust" "$ad3_out" "trusts whatever the destination holds"
assert_eq "without a local copy adoption needs --yes" "1" "$ad3_rc"
assert_contains "with --yes it is adopted" "$(omarchy-backup integrity record rc-1 --yes 2>&1)" "Recorded 'rc-1'"
mv "$WORK/rc-1-away" "$HOME/.local/share/omarchy-backup/snapshots/rc-1"
cp "$HOME/.local/share/omarchy-backup/snapshots/rc-1/payload.tar.zst" "$R2/rc-1/payload.tar.zst"
omarchy-backup integrity forget rc-1 >/dev/null 2>&1; omarchy-backup integrity record rc-1 >/dev/null 2>&1
# Pending uploads: only snapshots newer than the last successful upload.
jq '.created_epoch = 1' "$L2" > "$WORK/l2.json" && cp "$WORK/l2.json" "$L2"
omarchy-backup snapshot rc-old >/dev/null 2>&1
sleep 1
jq --argjson t "$(date +%s)" '.last_push_epoch = $t' "$HOME/.local/share/omarchy-backup/state.json" > "$WORK/r2s.json" \
  && cp "$WORK/r2s.json" "$HOME/.local/share/omarchy-backup/state.json"
sleep 1
mkdir -p "$R2/rc-old"; echo x > "$R2/rc-old/payload.tar.zst"
assert_contains "a folder named after an old local snapshot is a problem" "$(omarchy-backup integrity check 2>&1)" "added: rc-old/ (unknown folder)"
rm -rf "$R2/rc-old"
omarchy-backup snapshot rc-new --replace rc-old >/dev/null 2>&1
mkdir -p "$R2/rc-new"; echo x > "$R2/rc-new/payload.tar.zst"
assert_not_contains "a newer local snapshot's unfinished upload is not a problem" "$(omarchy-backup integrity check 2>&1)" "rc-new"
rm -rf "$R2/rc-new"
# Restore: an incomplete local folder is moved aside; old staging is swept.
rm -f "$HOME/.local/share/omarchy-backup/snapshots/rc-1/manifest.json"
printf '#!/bin/bash\necho changed\n' > "$HOME/.local/bin/mytool"
mkdir -p "$HOME/.local/share/omarchy-backup/.restore-stage.old1" "$HOME/.local/share/omarchy-backup/.restore-stage.new1" \
  "$HOME/.local/share/omarchy-backup/snapshots/.rc-9.pull.123"
touch -d '2 days ago' "$HOME/.local/share/omarchy-backup/.restore-stage.old1" "$HOME/.local/share/omarchy-backup/snapshots/.rc-9.pull.123"
st_out="$(omarchy-backup restore rc-1 --dry-run --accept-unverified 2>&1)"
assert_contains "an incomplete local snapshot is moved aside" "$st_out" "moved aside to"
assert_eq "it is kept under a stale name" "1" "$(ls -d "$HOME/.local/share/omarchy-backup/snapshots/rc-1.stale-"* 2>/dev/null | wc -l)"
assert_file "the restore downloads it again" "$HOME/.local/share/omarchy-backup/snapshots/rc-1/manifest.json"
assert_not_file "old staging leftovers are swept" "$HOME/.local/share/omarchy-backup/.restore-stage.old1"
assert_not_file "old pull leftovers are swept" "$HOME/.local/share/omarchy-backup/snapshots/.rc-9.pull.123"
assert_file "current staging folders are left alone" "$HOME/.local/share/omarchy-backup/.restore-stage.new1"
assert_contains "the full review is written to a file" "$st_out" "Full review: $HOME/.local/share/omarchy-backup/restore-review-rc-1-"
RVF="$(ls "$HOME/.local/share/omarchy-backup/restore-review-rc-1-"*.txt 2>/dev/null | head -n 1)"
assert_eq "the review file is private" "600" "$(stat -c %a "$RVF" 2>/dev/null)"
assert_contains "code is shown in full in the review file" "$(cat "$RVF")" "+echo hi"

echo "== integrity: a mounted destination shows the upload only later =="
# Upload through a mount (REMOTE_PATH), integrity listing straight from the
# backend (here: a second folder that catches up 3 s after each write, like
# rclone's VFS write-back). Recording waits for it; a backend that never
# shows the upload still fails the push.
HOME="$(new_home home_settle)"; omarchy-backup init >/dev/null 2>&1
seed_workspace "$HOME"
SM="$WORK/settle-mount"; SB="$WORK/settle-backend"; mkdir -p "$SM" "$SB"
sed -i "s|^OB_CFG_REMOTE_PATH=.*|OB_CFG_REMOTE_PATH=$SM|" "$HOME/.config/omarchy-backup/config.conf"
sed -i "s|^OB_CFG_INTEGRITY_RCLONE_REMOTE=.*|OB_CFG_INTEGRITY_RCLONE_REMOTE=$SB|" "$HOME/.config/omarchy-backup/config.conf"
LAG_BIN="$WORK/lag-bin"; mkdir -p "$LAG_BIN"
cat > "$LAG_BIN/rclone" <<LAG
#!/bin/bash
"$REAL_RCLONE" "\$@"; rc=\$?
case "\$1" in copy|copyto|moveto|move) [ -f "$WORK/settle-frozen" ] || ( sleep 3; cp -a "$SM/." "$SB/" ) >/dev/null 2>&1 & ;; esac
exit \$rc
LAG
chmod +x "$LAG_BIN/rclone"
omarchy-backup snapshot s-1 >/dev/null 2>&1
sl_rc=0; sl_out="$(PATH="$LAG_BIN:$PATH" OMARCHY_BACKUP_INTEGRITY_SETTLE_SECONDS=20 OMARCHY_BACKUP_INTEGRITY_SETTLE_POLL=1 omarchy-backup push s-1 2>&1)" || sl_rc=$?
assert_eq "a lagging backend is waited for (push succeeds)" "0" "$sl_rc"
assert_not_contains "nothing is reported as mismatched" "$sl_out" "does not match"
assert_eq "the upload is recorded" "true" "$(jq '.snapshots | has("s-1")' "$HOME/.local/share/omarchy-backup/integrity-ledger.json")"
assert_eq "the host-folder files are recorded" "true" "$(jq '.base.files | has("index.json")' "$HOME/.local/share/omarchy-backup/integrity-ledger.json")"
sleep 4
touch "$WORK/settle-frozen"
sleep 1
omarchy-backup snapshot s-2 >/dev/null 2>&1
sf_rc=0; sf_out="$(PATH="$LAG_BIN:$PATH" OMARCHY_BACKUP_INTEGRITY_SETTLE_SECONDS=2 OMARCHY_BACKUP_INTEGRITY_SETTLE_POLL=1 omarchy-backup push s-2 2>&1)" || sf_rc=$?
assert_eq "a backend that never shows the upload still fails the push" "75" "$sf_rc"
assert_contains "the failed record is explained" "$sf_out" "treating it as not uploaded"
assert_eq "the failed upload is not in the ledger" "false" "$(jq '.snapshots | has("s-2")' "$HOME/.local/share/omarchy-backup/integrity-ledger.json")"
assert_eq "recorded entries carry an MD5 (strong check)" "true" \
  "$(jq '[.snapshots["s-1"].files[] | .md5 | length == 32] | all' "$HOME/.local/share/omarchy-backup/integrity-ledger.json")"
# A backend that shows a tampered file the whole time is never recorded,
# however long recording waits.
omarchy-backup snapshot s-3 >/dev/null 2>&1
mkdir -p "$SB/$(hostname)/s-3"; cp "$HOME/.local/share/omarchy-backup/snapshots/s-3"/* "$SB/$(hostname)/s-3/"
printf x >> "$SB/$(hostname)/s-3/payload.tar.zst"
st_rc=0; st_out="$(PATH="$LAG_BIN:$PATH" OMARCHY_BACKUP_INTEGRITY_SETTLE_SECONDS=3 OMARCHY_BACKUP_INTEGRITY_SETTLE_POLL=1 omarchy-backup push s-3 2>&1)" || st_rc=$?
assert_eq "a tampered backend file fails the push despite waiting" "75" "$st_rc"
assert_contains "the tampered file is named" "$st_out" "s-3/payload.tar.zst does not match what was just uploaded"
assert_eq "the tampered upload is not in the ledger" "false" "$(jq '.snapshots | has("s-3")' "$HOME/.local/share/omarchy-backup/integrity-ledger.json")"

echo "== Summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
