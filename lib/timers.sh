#!/bin/bash
# Installs/refreshes the systemd --user timers driving automatic snapshot
# and doctor runs, based on config.conf. Re-run `omarchy-backup timers
# install` any time you change OB_CFG_SNAPSHOT_FREQUENCY / OB_CFG_DOCTOR_FREQUENCY.

ob_oncalendar_for() {
  case "$1" in
    daily|weekly|monthly) echo "$1" ;;
    "") echo "daily" ;;
    *) echo "$1" ;; # assume a literal systemd OnCalendar expression
  esac
}

ob_timers_install() {
  ob_ensure_dirs
  ob_load_config
  local exec_path; exec_path="$(command -v omarchy-backup || echo "$OB_ROOT_DIR/bin/omarchy-backup")"
  local unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir"

  local snap_cal doc_cal
  snap_cal="$(ob_oncalendar_for "$OB_CFG_SNAPSHOT_FREQUENCY")"
  doc_cal="$(ob_oncalendar_for "$OB_CFG_DOCTOR_FREQUENCY")"

  local f base
  for f in "$OB_ROOT_DIR"/systemd/omarchy-backup-*.service "$OB_ROOT_DIR"/systemd/omarchy-backup-*.timer; do
    base="$(basename -- "$f")"
    sed -e "s|@EXEC@|$exec_path|g" \
        -e "s|@ONCALENDAR_SNAPSHOT@|$snap_cal|g" \
        -e "s|@ONCALENDAR_DOCTOR@|$doc_cal|g" \
        "$f" > "$unit_dir/$base"
  done

  systemctl --user daemon-reload

  if [ "$OB_CFG_ENABLED" = "true" ]; then
    systemctl --user enable --now omarchy-backup-snapshot.timer omarchy-backup-doctor.timer
    ob_info "Timers installed and enabled: snapshot=$snap_cal, doctor=$doc_cal"
  else
    systemctl --user disable --now omarchy-backup-snapshot.timer omarchy-backup-doctor.timer 2>/dev/null || true
    ob_info "Timers installed but left disabled (OB_CFG_ENABLED=false in $OB_CONFIG_FILE)"
  fi
}

ob_timers_status() {
  systemctl --user list-timers 'omarchy-backup-*' --all 2>/dev/null
}

ob_timers_uninstall() {
  systemctl --user disable --now omarchy-backup-snapshot.timer omarchy-backup-doctor.timer 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user"/omarchy-backup-*.{service,timer}
  systemctl --user daemon-reload
  ob_info "Timers removed."
}
