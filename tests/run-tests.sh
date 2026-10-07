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
  if echo "$haystack" | grep -qF "$needle"; then ok "$desc"; else
    fail "$desc (did not find '$needle')"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then ok "$desc"; else
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
status_out="$(omarchy-backup status 2>&1)"
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
restore_out="$(HOME="$FRESH" omarchy-backup restore base 2>&1)"
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
HOME="$FRESH2" omarchy-backup restore base >/dev/null 2>&1
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
  HOME="$h" PATH="$STUB_BIN:$PATH" omarchy-backup restore pinned 2>&1
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
assert_contains "snapshot warns about unpushed commits" "$snap2_out" "unpushed commit(s)"

repo_restore_into() {
  local h; h="$(new_home "$1")"
  HOME="$h" omarchy-backup init >/dev/null 2>&1
  mkdir -p "$h/.local/share/omarchy-backup/snapshots/withrepo"
  cp "$RSNAP"/* "$h/.local/share/omarchy-backup/snapshots/withrepo/"
  shift
  HOME="$h" omarchy-backup restore withrepo "$@" 2>&1
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
b_out="$(HOME="$BLOCK" omarchy-backup restore withrepo 2>&1)"
assert_eq "existing non-git directory is left untouched" "keep" "$(cat "$BLOCK/Projects/tool/file")"
assert_contains "the skipped repo is listed as a manual step" "$b_out" "is not a git checkout; not touched"
# Hostile manifest path is refused.
EVIL="$(new_home repo_evil)"; HOME="$EVIL" omarchy-backup init >/dev/null 2>&1
mkdir -p "$EVIL/.local/share/omarchy-backup/snapshots/withrepo"; cp "$RSNAP"/* "$EVIL/.local/share/omarchy-backup/snapshots/withrepo/"
jq '.repos[0].path="../escape"' "$RSNAP/manifest.json" > "$EVIL/.local/share/omarchy-backup/snapshots/withrepo/manifest.json"
e_out="$(HOME="$EVIL" omarchy-backup restore withrepo 2>&1)"
assert_contains "a repo path escaping HOME is refused" "$e_out" "unsafe path"
assert_not_file "nothing is cloned outside HOME" "$WORK/escape"

echo "== restore without git access: embedded repo copy =="
assert_contains "manifest points at the embedded source copy" "$(jq -r '.repos[0].source_archive' "$RSNAP/manifest.json")" "repo-sources/Projects__tool.tar"
assert_contains "the embedded copy travels in the payload" "$(zstd -q -d -c "$RSNAP/payload.tar.zst" | tar -t)" ".local/share/omarchy-backup/repo-sources/Projects__tool.tar"
SRCS1="$(sha256sum < "$RSRC/.local/share/omarchy-backup/repo-sources/Projects__tool.tar")"
HOME="$RSRC" omarchy-backup snapshot unchanged-src >/dev/null 2>&1
assert_eq "an unchanged repo yields a byte-identical archive (no false drift)" "$SRCS1" \
  "$(sha256sum < "$RSRC/.local/share/omarchy-backup/repo-sources/Projects__tool.tar")"
OFFR="$WORK/repo_offline"
o_out="$(repo_restore_into repo_offline --repos-from-snapshot)"
assert_file "--repos-from-snapshot restores the tree" "$OFFR/Projects/tool/bin/tool"
assert_not_file "--repos-from-snapshot needs no clone (no .git)" "$OFFR/Projects/tool/.git"
assert_contains "the embedded copy includes tracked uncommitted edits" "$(cat "$OFFR/Projects/tool/bin/tool")" "local tweak"
assert_not_file "untracked files are not in the embedded copy" "$OFFR/Projects/tool/notes.txt"
assert_eq "restored link works from the embedded copy" "tool-v1" "$(HOME="$OFFR" "$OFFR/.local/bin/tool" 2>/dev/null | head -1 || true)"
assert_contains "restore explains how to reconnect git later" "$o_out" "git remote add origin $REPO_BARE"
DEADR="$(new_home repo_deadremote)"; HOME="$DEADR" omarchy-backup init >/dev/null 2>&1
mkdir -p "$DEADR/.local/share/omarchy-backup/snapshots/withrepo"; cp "$RSNAP"/* "$DEADR/.local/share/omarchy-backup/snapshots/withrepo/"
jq --arg r "$WORK/does-not-exist.git" '.repos[0].remote=$r' "$RSNAP/manifest.json" > "$DEADR/.local/share/omarchy-backup/snapshots/withrepo/manifest.json"
d_out="$(HOME="$DEADR" omarchy-backup restore withrepo 2>&1)"
assert_file "unreachable remote falls back to the embedded copy" "$DEADR/Projects/tool/bin/tool"
assert_contains "the fallback is reported" "$d_out" "restored from the snapshot's embedded copy (cloning failed)"

echo "== import: a snapshot folder obtained without rclone =="
DL="$WORK/downloaded/withrepo"; mkdir -p "$DL"; cp "$RSNAP"/* "$DL/"
IMP="$(new_home repo_import)"; HOME="$IMP" omarchy-backup init >/dev/null 2>&1
i_out="$(HOME="$IMP" omarchy-backup import "$DL" 2>&1)"
assert_contains "import names the next step" "$i_out" "omarchy-backup restore withrepo --dry-run"
assert_eq "imported snapshot is listed in state" "withrepo" "$(jq -r '.snapshots[0].name' "$IMP/.local/share/omarchy-backup/state.json")"
HOME="$IMP" omarchy-backup restore withrepo --repos-from-snapshot >/dev/null 2>&1
assert_file "imported snapshot restores" "$IMP/Projects/tool/bin/tool"
i2_rc=0; HOME="$IMP" omarchy-backup import "$DL" >/dev/null 2>&1 || i2_rc=$?
assert_eq "importing the same snapshot twice is refused" "1" "$i2_rc"
BAD="$WORK/downloaded/bad"; mkdir -p "$BAD"; cp "$RSNAP"/* "$BAD/"; jq '.name="badcopy"' "$RSNAP/manifest.json" > "$BAD/manifest.json"
printf 'x' >> "$BAD/payload.tar.zst"
IMP2="$(new_home repo_import_bad)"; HOME="$IMP2" omarchy-backup init >/dev/null 2>&1
b2_out="$(HOME="$IMP2" omarchy-backup import "$BAD" 2>&1)"
assert_contains "a corrupt download is refused" "$b2_out" "checksum mismatch"
assert_not_file "nothing is imported from a corrupt download" "$IMP2/.local/share/omarchy-backup/snapshots/badcopy"

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
echo "== Summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
