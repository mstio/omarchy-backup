# Security model

`omarchy-backup` runs as the current user. Restore may invoke `sudo pacman`,
install and enable Omarchy plugins, write user configuration and user systemd
units, and start units recorded in a snapshot. A restore is therefore a
high-trust operation even though normal snapshot/status commands are not.

## Enforced boundaries

- Snapshot names are one validated path component everywhere they are used.
- Remote `index.json` reads have producer-side byte limits, hard deadlines,
  bounded arrays/strings, strict field types/content, and unique safe names.
- Retention derives purge targets only beneath the configured host prefix after
  validation.
- Remote operations have hard deadlines; pulls request only the three expected
  snapshot files.
- Widget wrappers cap child output before JSON encoding and before Quickshell's
  `StdioCollector` sees it.
- Local configuration, state, logs, and snapshot files are owner-only.

## Trust assumptions and remaining hardening

The user decides whether a self-created snapshot and its storage location are
trusted enough to restore. Checksums and `rclone check` detect corruption and
incomplete transfer, but a party able to replace both payload and manifest can
create a self-consistent malicious snapshot. The tool exposes that boundary and
provides `restore --dry-run`; it does not take ownership of the user's trust
decision or forbid an explicitly requested restore.

Planned defense-in-depth work, in priority order:

1. Optionally add detached signatures or a MAC whose trust key is kept
   separately from the backup endpoint. Verification should give the user
   stronger evidence and a clear warning, while an explicit user override must
   remain possible. Authentication metadata must remain a detached sidecar: the
   standard `tar.zst` payload must always stay manually readable without this
   tool.
2. Strictly validate the complete restore manifest (package/plugin/unit names,
   commit IDs and remote URLs), use argument arrays/option terminators, and
   inspect archive paths/types before writing or enabling anything.
3. Cap downloaded snapshot bytes, decompressed bytes, archive members, and
   plugin-diff sizes to resist disk/memory/decompression denial of service.
4. Replace shell `source` loading of `config.conf` with a non-executing parser.
5. Add opt-in content-aware secret scanning; filename patterns alone cannot
   detect credentials embedded in otherwise ordinary configuration files or
   uncommitted plugin diffs.

Report vulnerabilities privately to the repository owner before opening a
public issue when disclosure would put existing backups at risk.
