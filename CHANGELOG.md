# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `--report` prints the reports already stored in an SQLite database and exits, formatted
  exactly like the log file and the console. Reading a database back no longer requires
  `sqlite3`.
- `--limit` controls how many reports `--report` prints, newest last, like `tail`
  (default: 20).
- `--follow` keeps printing reports as the running `qwatcher` stores them, the `tail -f`
  equivalent. It tracks position by row id, so no report is repeated or skipped, and it
  implies `--report`.
- A `Release` GitHub Actions workflow that builds on tag pushes, refuses to publish when
  the tag does not match the version in `qwatcher.nimble`, smoke tests the archive by
  running the binary against the kernel, and publishes it with the `gh` CLI.

### Changed

- The default refresh interval is 5 seconds, down from 10. A poll costs roughly 9 ms on a
  host with about 100 connections and 19 ms with about 4000, so the limiting factor on a
  short interval is row volume rather than CPU.
- The `/proc` scan that names processes now looks only for the socket inodes that actually
  breached, and stops as soon as it has found them all, instead of mapping every socket on
  the host.
- Nim requirement raised to `2.2.12`.

## [0.5.0] - 2026-09-12

### Added

- `nimble release` builds a stripped binary and packages it with the systemd unit and
  licence into `qwatcher.tar.gz`, so a release is one command.
- IPv6 connections are reported correctly, with addresses bracketed as `[address]:port`.
- The systemd unit is sandboxed: `NoNewPrivileges`, `ProtectSystem=strict`,
  `ReadWritePaths=/var/log`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`,
  `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`,
  `RestrictAddressFamilies=AF_NETLINK`, `RestrictNamespaces`, `RestrictSUIDSGID`,
  `MemoryDenyWriteExecute` and `LockPersonality`.
- An installation guide covering release archives, Nimble, building from source and
  running as a service.

### Changed

- **`ss` is no longer used.** Connection data now comes from the kernel directly over
  `NETLINK_SOCK_DIAG`, the same interface `ss` uses. No subprocess is spawned, no command
  output is parsed and no regular expressions are involved, which also drops the PCRE
  dependency — the binary now links only against `libc`.
- The `Info` field is trimmed to what diagnosing a stuck queue actually needs: `skmem`,
  `rto`, `rtt`, `minrtt`, `mss`, `cwnd` and `retrans`.
- SQLite handling follows the usual practice for a long running writer. The database is
  opened once at startup instead of once per row, the insert is a prepared statement
  reused across reports, each poll commits as a single transaction, and the connection is
  closed cleanly on `SIGINT` and `SIGTERM`. `journal_mode=WAL` lets you query the database
  while `qwatcher` is writing to it, with `synchronous=NORMAL` and `busy_timeout=5000`.
- The database schema is typed and no longer stores everything as text. `receiveQ`,
  `sendQ`, `localPort` and `remotePort` are `INTEGER`, addresses and ports are separate
  columns, timestamps are ISO-8601 and sort chronologically, and `time` is indexed.
  Existing databases are not migrated.
- Process names are resolved only for connections that breach a threshold.
- Reports are written in one batch per poll rather than one file open per report.
- Databases and log files are created with `0600` permissions, since reports contain the
  addresses and processes of every connection on the host.

### Fixed

- `getArgs` advanced the option parser twice per iteration, so every second flag was
  silently ignored. `qwatcher --recv_q:X --send_q:Y --refresh:Z --db_path:P` never reached
  `--db_path`.
- `--refresh` was treated as milliseconds while being documented as seconds, so
  `--refresh:5` polled every 5 milliseconds.
- `--db_path` was silently discarded whenever `--log_path` was also set, regardless of
  `--stdout`. The three output flags are now mutually exclusive and validated.
- IPv6 addresses were split on `:` and mangled into unusable values.
- Ports were stored as service names such as `https`, because `ss` resolved them.
- Invalid flag values crashed with an unhandled `ValueError` instead of reporting the
  problem. Unknown flags and stray arguments are now rejected.
- `db_connector` was missing from `qwatcher.nimble`, so a clean checkout could not build.
- The systemd unit specified `After=Network.target`, which never matched because unit
  names are case sensitive, and set `RemainAfterExit=yes`, which does not apply to
  `Type=simple`.
- The release archive shipped a binary without the executable bit, which is why
  installation required `chmod +x`.

## [0.4.0] - 2025-11-02

See the [releases page](https://github.com/pouriyajamshidi/qwatcher/releases) for earlier
history.

[Unreleased]: https://github.com/pouriyajamshidi/qwatcher/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/pouriyajamshidi/qwatcher/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/pouriyajamshidi/qwatcher/releases/tag/v0.4.0
