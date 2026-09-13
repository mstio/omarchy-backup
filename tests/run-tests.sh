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

assert_file() {
  local desc="$1" path="$2"
  if [ -e "$path" ]; then ok "$desc"; else fail "$desc (missing: $path)"; fi
}

new_home() {
  local h="$WORK/$1"
  mkdir -p "$h"
  echo "$h"
}

configure_remote() {
  local home="$1"
  sed -i 's/^OB_CFG_REMOTE_NAME=.*/OB_CFG_REMOTE_NAME=testlocal/' "$home/.config/omarchy-backup/config.conf"
  sed -i "s|^OB_CFG_REMOTE_PATH=.*|OB_CFG_REMOTE_PATH=$REMOTE_STORAGE/omarchy-backup|" "$home/.config/omarchy-backup/config.conf"
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

echo "== 2. snapshot + baseline =="
seed_workspace "$HOME"
out="$(omarchy-backup snapshot base --baseline 2>&1)"
assert_contains "snapshot created" "$out" "Snapshot 'base' created"
assert_file "snapshot dir exists" "$HOME/.local/share/omarchy-backup/snapshots/base/manifest.json"
assert_file "payload exists" "$HOME/.local/share/omarchy-backup/snapshots/base/payload.tar.zst"
assert_file "checksums exist" "$HOME/.local/share/omarchy-backup/snapshots/base/checksums.sha256"

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

echo
echo "== Summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
