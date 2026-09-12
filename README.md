# Queue Watcher

<!-- ![qwatcher](artwork/qwatcher.png) -->
<!-- <img src="https://github.com/pouriyajamshidi/qwatcher/blob/master/artwork/qwatcher.png?raw=true" width="600" /> -->

<div align="center" style="width: 100%;">
 <img alt="qwatcher" src="https://github.com/pouriyajamshidi/qwatcher/blob/master/artwork/qwatcher.png?raw=true" width="700">
</div>

---

`qwatcher` is designed to help monitor TCP connections and diagnose **buffer** and connectivity issues on Linux machines related to `input` and `output` queues.

It talks to the kernel directly over `NETLINK_SOCK_DIAG` — the same interface `ss` uses — so it has no external dependencies, spawns no processes and parses no command output.

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
  - [What](#what)
  - [Querying the database](#querying-the-database)
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

`qwatcher` is a single binary that talks to the kernel directly — it needs no `ss`, no
`iproute2` and no shell. Beyond `libc`, its only runtime requirement is `libsqlite3`, and
only when you use `--db_path`. That library ships with virtually every distribution;
install `libsqlite3-0` (Debian/Ubuntu) or `sqlite-libs` (RHEL/Fedora/Alpine) if it is
missing.

### From a release

```bash
wget https://github.com/pouriyajamshidi/qwatcher/releases/latest/download/qwatcher.tar.gz && \
  tar xvf qwatcher.tar.gz && \
  sudo install -m 755 qwatcher /usr/local/bin/qwatcher && \
  qwatcher --version
```

### With Nimble

```bash
nimble install qwatcher
```

This drops the binary in `~/.nimble/bin/qwatcher`. Copy it to `/usr/local/bin` if you
intend to use the systemd unit, which expects it there.

### From source

Requires Nim `>= 2.2.6`. Nimble pulls in the only dependency, `db_connector`.

```bash
git clone https://github.com/pouriyajamshidi/qwatcher.git && \
  cd qwatcher && \
  nimble build -d:release && \
  sudo install -m 755 qwatcher /usr/local/bin/qwatcher && \
  qwatcher --version
```

### Run it as a service

The [accompanying systemd unit](qwatcher.service) keeps `qwatcher` running in the
background and across reboots. It runs as `root`, which is what lets it name the process
behind each connection, and it is sandboxed (`ProtectSystem=strict`, `PrivateDevices`,
`RestrictAddressFamilies=AF_NETLINK`, and friends).

Fetch the unit, install it and start it — this works regardless of how you installed the
binary above:

```bash
sudo curl -fsSL -o /etc/systemd/system/qwatcher.service \
  https://raw.githubusercontent.com/pouriyajamshidi/qwatcher/master/qwatcher.service && \
  sudo systemctl daemon-reload && \
  sudo systemctl enable --now qwatcher.service && \
  systemctl status qwatcher.service --no-pager
```

If you cloned the repository, use the local copy instead of downloading it:

```bash
sudo cp qwatcher.service /etc/systemd/system/qwatcher.service && \
  sudo systemctl daemon-reload && \
  sudo systemctl enable --now qwatcher.service && \
  systemctl status qwatcher.service --no-pager
```

It starts with these defaults, which you can change at any time:

```ini
ExecStart=/usr/local/bin/qwatcher --recv_q:100000 --send_q:100000 --db_path:/var/log/qwatcher.db
```

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
> only your own processes can be identified — everything else is reported as `No process`.

> :warning: Make sure to not feed a higher number than your current buffer size to the program.

In order to get the current read and write buffer sizes, run the following commands:

```bash
cat /proc/sys/net/ipv4/tcp_rmem
cat /proc/sys/net/ipv4/tcp_wmem
```

---

### Usage

Let's explore all modes:

1. check every **5 seconds** and **log** connections that surpass **100 kilobytes** in **send** or **receive** queues to a **database** located at `/var/log/qwatcher.db`:

   ```bash
   qwatcher --recv_q=100000 --send_q=100000 --refresh=5 --db_path=/var/log/qwatcher.db
   ```

   The database is opened in [WAL](https://www.sqlite.org/wal.html) mode, so you can
   query it at any time without interrupting the running `qwatcher`. See
   [Querying the database](#querying-the-database).

2. Should you prefer to log the stats in a **log file** instead of a database as shown in step 1 use `--log_path`:

   ```bash
   qwatcher --recv_q=100000 --send_q=100000 --refresh=5 --log_path=/var/log/qwatcher.log
   ```

   Then you can use tail to check the file contents:

   ```bash
   tail -f /var/log/qwatcher.log
   ```

3. **Default mode**. If you want the output to be shown on the **console** and not log to disk, use the commands above without `--log_path` or `--db_path` options:

   ```bash
   qwatcher --recv_q=100000 --send_q=100000
   ```

   > The default refresh interval is 10 seconds.

The sample output can be seen [here](#what)

To keep it running in the background, see [Run it as a service](#run-it-as-a-service).

### Available flags

```console
  --recv_q,   INT    : Minimum Receive Queue in bytes to trigger a report (default: 10000)
  --send_q,   INT    : Minimum Send Queue in bytes to trigger a report (default: 10000)
  --refresh,  INT    : Refresh interval in seconds (default: 10)
  --db_path,  STRING : Path to an SQLite database to log reports to
  --log_path, STRING : Path to a log file to write reports to
  --stdout           : Print reports to the console (default)
  -h, --help         : Show help
  -v, --version      : Show version

  For instance:

  qwatcher --recv_q:100000 --send_q:100000 --db_path:/var/log/qwatcher.db
  qwatcher --recv_q:100000 --send_q:100000 --log_path:/var/log/qwatcher.log
  qwatcher --recv_q:100000 --send_q:100000 --stdout
```

> Please note that `--db_path`, `--log_path` and `--stdout` are mutually exclusive.

---

## What

Below output depicts the provided information for a connection:

![output](https://github.com/pouriyajamshidi/qwatcher/raw/master/images/qwatcher.png)

Apart from the send and receive queues, the `Info` field carries the numbers that matter
when diagnosing a stuck queue:

| Field    | Meaning                                                       |
| -------- | ------------------------------------------------------------- |
| `skmem`  | `r`/`rb` receive buffer used/limit, `t`/`tb` send buffer used/limit |
| `rto`    | Retransmission timeout in milliseconds                        |
| `rtt`    | Round trip time / variance in milliseconds                    |
| `minrtt` | Lowest round trip time observed on the connection             |
| `mss`    | Maximum segment size                                          |
| `cwnd`   | Congestion window in segments                                 |
| `retrans`| Currently outstanding / total retransmits, shown when non-zero |

## Querying the database

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
```

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
