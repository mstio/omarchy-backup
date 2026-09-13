#!/bin/bash
# `omarchy-backup config get/set/list` -- lets the bar-widget dialog (and
# anyone else) read/write config.conf without hand-rolling sed against it.
# Only the documented OB_CFG_* keys are writable, each with the same
# validation the widget's dropdowns/toggles rely on.

# key -> validator function name. A key not listed here is never accepted.
declare -A OB_CFG_VALIDATORS=(
  [OB_CFG_ENABLED]=ob_cfg_validate_bool
  [OB_CFG_SNAPSHOT_FREQUENCY]=ob_cfg_validate_frequency
  [OB_CFG_DOCTOR_FREQUENCY]=ob_cfg_validate_frequency
  [OB_CFG_REMOTE_NAME]=ob_cfg_validate_anything
  [OB_CFG_REMOTE_PATH]=ob_cfg_validate_anything
  [OB_CFG_RETENTION_REMOTE]=ob_cfg_validate_posint
  [OB_CFG_MAX_FILE_SIZE_MB]=ob_cfg_validate_posint
  [OB_CFG_SKIP_AUTO_IF_CLEAN]=ob_cfg_validate_bool
)

ob_cfg_validate_bool() { case "$1" in true|false) return 0 ;; *) return 1 ;; esac; }
ob_cfg_validate_frequency() { case "$1" in daily|weekly|monthly) return 0 ;; *) return 1 ;; esac; }
ob_cfg_validate_posint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) [ "$1" -gt 0 ]; esac; }
ob_cfg_validate_anything() {
  # Remote name/path: reject characters that would break the KEY=VALUE line
  # or that rclone/sed would choke on -- newlines and '|' (our sed delimiter).
  case "$1" in *$'\n'*|*'|'*) return 1 ;; *) return 0 ;; esac
}

ob_config_known_keys() { printf '%s\n' "${!OB_CFG_VALIDATORS[@]}" | sort; }

ob_config_list() {
  ob_ensure_dirs
  ob_load_config
  local k
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    jq -n --arg k "$k" --arg v "${!k:-}" '{key:$k, value:$v}'
  done < <(ob_config_known_keys) | jq -s .
}

ob_config_get() {
  local key="$1"
  [ -n "${OB_CFG_VALIDATORS[$key]:-}" ] || ob_die "Unknown config key: $key"
  ob_ensure_dirs
  ob_load_config
  echo "${!key:-}"
}

ob_config_set() {
  local key="$1" value="$2"
  local validator="${OB_CFG_VALIDATORS[$key]:-}"
  [ -n "$validator" ] || ob_die "Unknown or unsettable config key: $key"
  "$validator" "$value" || ob_die "Invalid value for $key: $value"

  ob_ensure_dirs

  # config.conf is bash-`source`d, so the value MUST be single-quoted here --
  # an unquoted value containing a space (e.g. an rclone remote name like
  # "gdrive omarchy") would otherwise parse as `KEY=word command...`,
  # silently running the rest of the value as a command on every load. Do
  # not "simplify" this back to a bare sed substitution.
  local escaped_value quoted_line
  escaped_value="${value//\'/\'\\\'\'}"
  quoted_line="${key}='${escaped_value}'"

  local tmp="$OB_CONFIG_FILE.tmp.$$" found=false line
  : > "$tmp"
  if [ -f "$OB_CONFIG_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "${key}="*)
          printf '%s\n' "$quoted_line" >> "$tmp"
          found=true
          ;;
        *)
          printf '%s\n' "$line" >> "$tmp"
          ;;
      esac
    done < "$OB_CONFIG_FILE"
  fi
  if [ "$found" = false ]; then
    printf '%s\n' "$quoted_line" >> "$tmp"
  fi
  mv -- "$tmp" "$OB_CONFIG_FILE"
  ob_info "Set $key=$value in $OB_CONFIG_FILE"
}
