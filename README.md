# Queue Watcher

`qwatcher` is designed to help monitor TCP connections and diagnose **buffer** and connectivity issues on Linux machines related to `input` and `output` queues.

## Why

The idea of writing this program came to me after reading a few blog posts discussing how they faced odd connectivity issues and how it ended up being related to the send and receive queues.

Had they had this tool, they would have been able to find the root cause much faster.

## How

1. Download and unzip the archive file from this URL:

   ```bash
   wget https://github.com/pouriyajamshidi/qwatcher/releases/latest/download/qwatcher.zip
   unzip qwatcher.zip
   ```

2. Make it executable and if you prefer, move it to your `$PATH`:

   ```bash
   chmod +x qwatcher
   sudo cp qwatcher /usr/local/bin
   ```

3. Run it. There are two modes to run `qwatcher`.

   1. Log mode (default): Logs the output to `/var/log/qwatcher.log`
   2. Monitor mode: Prints the output to the console with `--show_only` option

> :warning: Make sure to not feed a higher number than your current buffer size to the program.
> In order to get the current read and write buffer sizes, run the following commands:

```bash
cat /proc/sys/net/ipv4/tcp_rmem
cat /proc/sys/net/ipv4/tcp_wmem
```

---

Let's explore both modes:

1. check every **5 seconds** and **log** connections that surpass **100 kilobytes** in **send** or **receive** queues in `/var/log/qwatcher.log`:

   ```bash
   qwatcher --recv_q=100000 --send_q=100000 --refresh=5
   ```

   Then you can use tail to check the file contents:

   ```bash
   tail -f /var/log/qwatcher.log
   ```

2. If you want the output to be shown on the **console** and not log to file, use the `--show_only` option:

   ```bash
   qwatcher --recv_q=100000 --send_q=100000 --show_only
   ```

   > The default refresh interval is 10 seconds.

The sample output can be seen [here](#what)

Additionally, you can use the [accompanying systemd](qwatcher.service) service to run `qwatcher` in the background and not worry about system restarts:

```bash
sudo cp qwatcher.service /etc/systemd/system/qwatcher.service
sudo systemctl enable qwatcher.service
sudo systemctl start qwatcher.service
```

### Available flags

```console
  -h, --help       : show help
  --recv_q,        : Minimum receive-Q to trigger alert in bytes (default: 10000)
  --send_q,        : Minimum send-Q to trigger alert in bytes (default: 10000)
  --refresh,       : Refresh interval in seconds (default: 10)
  --show_only,     : Show only the current state without logging to file
  -v, --version,   : Show version
```

## What

Below output depicts the provided information for a connection:

![output](https://github.com/pouriyajamshidi/qwatcher/raw/master/images/qwatcher.png)

Apart from the send and receive queues, there are additional information that can be useful to diagnose connectivity issues such as `congestion window`, `mss`, `retransmits` and more.

## Tested on

Ubuntu server 22.04.

## Sponsor me

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/pouriyajamshidi)  
[![sponsor](https://img.shields.io/static/v1?label=Sponsor&message=%E2%9D%A4&logo=GitHub&color=%23fe8e86)](https://github.com/sponsors/pouriyajamshidi)

## Contact me

[![LinkedIn](https://img.shields.io/badge/LinkedIn-0077B5?style=for-the-badge&logo=linkedin&logoColor=white)](https://www.linkedin.com/in/pouriya-jamshidi/)

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
