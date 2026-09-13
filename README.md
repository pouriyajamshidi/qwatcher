# Queue Watcher

<!-- ![qwatcher](artwork/qwatcher.png) -->
<!-- <img src="https://github.com/pouriyajamshidi/qwatcher/blob/master/artwork/qwatcher.png?raw=true" width="600" /> -->

<div align="center" style="width: 100%;">
 <img alt="qwatcher" src="https://github.com/pouriyajamshidi/qwatcher/blob/master/artwork/qwatcher.png?raw=true" width="700">
</div>

---

`qwatcher` is designed to help monitor TCP connections and diagnose **buffer** and connectivity issues on Linux machines related to `input` and `output` queues.

It talks to the kernel directly over `NETLINK_SOCK_DIAG`, the same interface `ss` uses, so it needs no external tooling, spawns no processes and parses no command output.

---

## Table of Contents

- [Queue Watcher](#queue-watcher)
  - [Table of Contents](#table-of-contents)
  - [Why](#why)
  - [Install](#install)
    - [From a release](#from-a-release)
    - [With Nimble](#with-nimble)
    - [From source](#from-source)
    - [Run it as a service](#run-it-as-a-service)
  - [How](#how)
    - [Usage](#usage)
    - [Available flags](#available-flags)
    - [Choosing a refresh interval](#choosing-a-refresh-interval)
  - [What](#what)
  - [Querying the database](#querying-the-database)
  - [Changelog](#changelog)
  - [Nimble Directory](#nimble-directory)
  - [Tested on](#tested-on)
  - [Sponsor me](#sponsor-me)
  - [Contact me](#contact-me)
  - [License](#license)

---

## Why

The idea of writing this program came to me after reading a few blog posts discussing how they faced odd connectivity issues and how it ended up being related to the send and receive queues.

Had they had this tool, they would have been able to find the root cause much faster.

---

## Install

`qwatcher` is a single binary that talks to the kernel directly. It needs no `ss`, no
`iproute2` and no shell. It links against `libc` and loads `libsqlite3` at startup, in
every mode, so that library must be present even when you are not using `--db_path`. It
ships with virtually every distribution; install `libsqlite3-0` (Debian/Ubuntu) or
`sqlite-libs` (RHEL/Fedora/Alpine) if it is missing.

SQLite is loaded from the system rather than linked in, so `qwatcher` uses whatever
version and build the host provides.

### From a release

```bash
wget https://github.com/pouriyajamshidi/qwatcher/releases/latest/download/qwatcher.tar.gz && \
  tar xvf qwatcher.tar.gz && \
  sudo install -m 755 qwatcher /usr/local/bin/qwatcher && \
  qwatcher --version
```

The archive also carries `qwatcher.service`, so you have everything you need for
[running it as a service](#run-it-as-a-service).

### With Nimble

```bash
nimble install qwatcher
```

This drops the binary in `~/.nimble/bin/qwatcher`. Copy it to `/usr/local/bin` if you
intend to use the systemd unit, which expects it there.

### From source

Requires Nim `>= 2.2.12`. Nimble pulls in the only dependency, `db_connector`.

```bash
git clone https://github.com/pouriyajamshidi/qwatcher.git && \
  cd qwatcher && \
  nimble build -d:release && \
  sudo install -m 755 qwatcher /usr/local/bin/qwatcher && \
  qwatcher --version
```

To produce the same stripped binary and `qwatcher.tar.gz` that the releases are built
from, run `nimble release` instead of `nimble build`.

### Run it as a service

The [accompanying systemd unit](qwatcher.service) keeps `qwatcher` running in the
background and across reboots. It runs as `root`, which is what lets it name the process
behind each connection, and it is sandboxed (`ProtectSystem=strict`, `PrivateDevices`,
`RestrictAddressFamilies=AF_NETLINK`, and friends).

`qwatcher.service` ships in the release archive and in the repository, so from either one:

```bash
sudo cp qwatcher.service /etc/systemd/system/qwatcher.service && \
  sudo systemctl daemon-reload && \
  sudo systemctl enable --now qwatcher.service && \
  systemctl status qwatcher.service --no-pager
```

If you installed with `nimble install`, you only got the binary, so fetch the unit first:

```bash
sudo curl -fsSL -o /etc/systemd/system/qwatcher.service \
  https://raw.githubusercontent.com/pouriyajamshidi/qwatcher/master/qwatcher.service && \
  sudo systemctl daemon-reload && \
  sudo systemctl enable --now qwatcher.service && \
  systemctl status qwatcher.service --no-pager
```

It starts with these settings, which you can change at any time:

```ini
ExecStart=/usr/local/bin/qwatcher --recv_q:100KB --send_q:1MB --db_path:/var/log/qwatcher.db
```

These are deliberately looser than the 10 kB built-in default so a standing service does
not fill the database with short spikes and normal bulk transfers.

To use your own thresholds or output path, edit the unit and reload:

```bash
sudo systemctl edit --full qwatcher.service && \
  sudo systemctl restart qwatcher.service && \
  systemctl status qwatcher.service --no-pager
```

> :warning: The sandbox only grants write access to `/var/log` via `ReadWritePaths=`.
> If you point `--db_path` or `--log_path` somewhere else, add that directory to
> `ReadWritePaths=` too. Otherwise the service exits with
> `unable to open database file` and restart-loops.

Follow it live, or stop it entirely:

```bash
journalctl -u qwatcher.service -f
```

```bash
sudo systemctl disable --now qwatcher.service
```

A clean stop lets `qwatcher` close the database properly, so no `-wal` file is left
behind.

---

## How

There are two modes to run `qwatcher`.

1. **Write mode**. Provides two logging methods:
   1. Using `--db_path` to log to an SQLite database
   2. Using `--log_path` to log to a text file
2. **Monitor mode** (default). Prints the output to the console

Both write modes create their file with `0600` permissions, since the reports contain the
addresses and processes of every connection on the host.

> :bulb: Run `qwatcher` as `root` to see the process behind each connection. Without it,
> only your own processes can be identified, and everything else is reported as `No process`.

> :warning: Make sure to not feed a higher number than your current buffer size to the program.

In order to get the current read and write buffer sizes, run the following commands:

```bash
cat /proc/sys/net/ipv4/tcp_rmem
cat /proc/sys/net/ipv4/tcp_wmem
```

---

### Usage

Two flags carry units that are easy to mix up:

| Flag                   | Unit        | Meaning                                        |
| ---------------------- | ----------- | ---------------------------------------------- |
| `--recv_q`, `--send_q` | **size**    | How full a queue must be to be worth reporting |
| `--refresh`            | **seconds** | How often to ask the kernel                    |

A size is plain bytes or a number with a unit: `100000`, `100KB`, `1.5MB`, `64KiB`
(`KB` is 1000 bytes, `KiB` is 1024). Timing is controlled only by `--refresh`.

Both queue thresholds default to **10 kB**. A report is made when **either** queue reaches
its threshold.

> :bulb: A Receive-Q that stays full means the application is not reading, which is
> almost always a problem. A Send-Q of hundreds of kB or more is normal during bulk
> transfers, so a higher send threshold such as `1MB` keeps the noise down.

Let's explore all modes:

1. check every **5 seconds** and **log** connections whose **receive** queue reaches **100 kB** or whose **send** queue reaches **1 MB** to a **database** located at `/var/log/qwatcher.db`:

   ```bash
   qwatcher --recv_q:100KB --send_q:1MB --refresh:5 --db_path:/var/log/qwatcher.db
   ```

   The database is opened in [WAL](https://www.sqlite.org/wal.html) mode, so you can
   query it at any time without interrupting the running `qwatcher`. See
   [Querying the database](#querying-the-database).

2. Should you prefer to log the stats in a **log file** instead of a database as shown in step 1 use `--log_path`:

   ```bash
   qwatcher --recv_q:100KB --send_q:1MB --refresh:5 --log_path:/var/log/qwatcher.log
   ```

   Then you can use tail to check the file contents:

   ```bash
   tail -f /var/log/qwatcher.log
   ```

3. **Default mode**. If you want the output to be shown on the **console** and not log to disk, use the commands above without `--log_path` or `--db_path` options:

   ```bash
   # no --refresh, so the 5 second default applies
   qwatcher --recv_q:100KB --send_q:1MB
   ```

The sample output can be seen [here](#what)

To keep it running in the background, see [Run it as a service](#run-it-as-a-service).

### Available flags

```console
  --recv_q,   SIZE   : Minimum Receive Queue to trigger a report (default: 10KB)
  --send_q,   SIZE   : Minimum Send Queue to trigger a report (default: 10KB)
  --refresh,  INT    : Refresh interval in seconds (default: 5)
  --db_path,  STRING : Path to an SQLite database to log reports to
  --log_path, STRING : Path to a log file to write reports to
  --stdout           : Print reports to the console (default)
  --report           : Print the reports already stored in --db_path and exit
  --limit,    INT    : How many reports --report prints, newest last (default: 20)
  --follow           : Keep printing reports as they are stored, like `tail -f`
  -h, --help         : Show help
  -v, --version      : Show version

  For instance:

  qwatcher --recv_q:100KB --send_q:1MB --db_path:/var/log/qwatcher.db
  qwatcher --recv_q:100KB --send_q:1MB --log_path:/var/log/qwatcher.log
  qwatcher --recv_q:100KB --send_q:1MB --stdout

  SIZE is bytes, or a number with a unit: 10KB, 1.5MB, 64KiB (KB = 1000, KiB = 1024).

  qwatcher --db_path:/var/log/qwatcher.db --report
  qwatcher --db_path:/var/log/qwatcher.db --report --limit:100
  qwatcher --db_path:/var/log/qwatcher.db --follow
```

> `--recv_q` and `--send_q` are **sizes**; `--refresh` is in **seconds**. A value like
> `100KB` is a queue size, never a duration.

### Choosing a refresh interval

> :warning: **Upgrading from 0.4.0 or earlier?** `--refresh` used to be read as
> milliseconds despite being documented as seconds. A `--refresh:10000` that used to mean
> "ten seconds" now means 10000 seconds, just under three hours. Divide any existing
> `--refresh` value by 1000, or drop the flag and take the 5 second default. See the
> [changelog](CHANGELOG.md) for the other breaking changes in 0.5.0.

A poll costs about 9 ms on a host with ~100 connections and about 19 ms with ~4000, plus
roughly 45 ms to name the processes whenever something actually breaches. So even
`--refresh:1` costs only a few percent of one core. The real cost of a short interval is
row volume in the database, not CPU. The 5 second default is a reasonable standing watch;
drop to `--refresh:1` while actively chasing a problem.

> Please note that `--db_path`, `--log_path` and `--stdout` are mutually exclusive.

---

## What

Below output depicts the provided information for a connection:

```console
======================================================================
Time:           2026-09-12T17:41:12
State:          ESTAB
Receive-Q:      0
Send-Q:         7357
Local Address:  192.168.1.20:46412
Remote Address: 203.0.113.10:443
Process:        code(pid=340003,fd=25)
Info:           skmem:(r0,rb131072,t0,tb87040) rto:588 rtt:340.990/42.552 minrtt:303.347 mss:1428 cwnd:5 retrans:0/8
======================================================================
======================================================================
Time:           2026-09-12T17:41:12
State:          CLOSE-WAIT
Receive-Q:      437
Send-Q:         0
Local Address:  [2001:db8:85a3::8a2e:370:7334]:43008
Remote Address: [2001:db8:f00::347]:443
Process:        gnome-software(pid=3349,fd=39)
Info:           skmem:(r2880,rb1536115,t0,tb87040) rto:222 rtt:21.915/4.614 minrtt:10.823 mss:1428 cwnd:10 retrans:0/6
======================================================================
```

IPv6 addresses are bracketed so the port stays readable. The same format is used for the
console, the log file and `--report`.

Apart from the send and receive queues, the `Info` field carries the numbers that matter
when diagnosing a stuck queue:

| Field     | Meaning                                                             |
| --------- | ------------------------------------------------------------------- |
| `skmem`   | `r`/`rb` receive buffer used/limit, `t`/`tb` send buffer used/limit |
| `rto`     | Retransmission timeout in milliseconds                              |
| `rtt`     | Round trip time / variance in milliseconds                          |
| `minrtt`  | Lowest round trip time observed on the connection                   |
| `mss`     | Maximum segment size                                                |
| `cwnd`    | Congestion window in segments                                       |
| `retrans` | Currently outstanding / total retransmits, shown when non-zero      |

## Querying the database

The quickest way to read a database back is `qwatcher` itself. No `sqlite3` is needed, and
the output is formatted exactly like the log file and the console:

```bash
qwatcher --db_path:/var/log/qwatcher.db --report
```

It prints the 20 most recent reports, newest last, the way `tail` does. Use `--limit` for
more:

```bash
qwatcher --db_path:/var/log/qwatcher.db --report --limit:100
```

`--follow` is the `tail -f` equivalent: it prints the recent reports and then keeps
printing new ones as the running `qwatcher` stores them, until you interrupt it.

```bash
qwatcher --db_path:/var/log/qwatcher.db --follow
```

It checks for new rows every `--refresh` seconds, so pair it with the interval the writer
is using. Because the database is in WAL mode, all of this works while `qwatcher` is
running and writing to that same file.

For anything beyond reading reports back (grouping, filtering, aggregating), use `sqlite3`
directly.

> `sqlite3` needs to be installed.

```bash
# Open the database file:
sqlite3 /var/log/qwatcher.db
# Beautify sqlite output:
.mode line
.headers on
# Connections that had anything waiting in the receive queue:
sqlite> SELECT * FROM qwatcher WHERE receiveQ > 0 ORDER BY receiveQ DESC;
# The worst offenders, grouped by process:
sqlite> SELECT process, MAX(receiveQ), MAX(sendQ), COUNT(*)
   ...>   FROM qwatcher GROUP BY process ORDER BY 2 DESC;
```

The schema is:

```sql
CREATE TABLE qwatcher (
  id            INTEGER PRIMARY KEY,
  time          TEXT    NOT NULL,  -- ISO-8601, sorts chronologically
  state         TEXT    NOT NULL,
  receiveQ      INTEGER NOT NULL,
  sendQ         INTEGER NOT NULL,
  localAddress  TEXT    NOT NULL,
  localPort     INTEGER NOT NULL,
  remoteAddress TEXT    NOT NULL,
  remotePort    INTEGER NOT NULL,
  process       TEXT    NOT NULL,
  info          TEXT    NOT NULL
);
CREATE INDEX qwatcher_time_idx ON qwatcher(time);
```

## Changelog

Notable changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## Nimble Directory

This project is also hosted on [Nimble](https://nimble.directory/pkg/qwatcher).

## Tested on

Ubuntu server 22.04. Requires Linux 3.3 or newer for the `sock_diag` interface.

## Sponsor me

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/pouriyajamshidi)
[![sponsor](https://img.shields.io/static/v1?label=Sponsor&message=%E2%9D%A4&logo=GitHub&color=%23fe8e86)](https://github.com/sponsors/pouriyajamshidi)

## Contact me

[![LinkedIn](https://img.shields.io/badge/LinkedIn-0077B5?style=for-the-badge&logo=linkedin&logoColor=white)](https://www.linkedin.com/in/pouriya-jamshidi/)

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
