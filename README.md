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

```console
======================================================================
Time:           2022-08-07 - 13:24:27
State:          ESTAB
Receive-Q:      0
Send-Q:         93239
Local Address:  145.55.162.71:443
Remote Address: 1.214.249.20:15637
Process:        timer:(on,740ms,0)

Info:   skmem:(r0,rb425984,t0,tb425984,f6601,w136759,o0,bl0,d3) ts sack bbr wscale:8,2 rto:788 rtt:366.822/52.165 ato:40 mss:1378 pmtu:1500 rcvmss:1332 advmss:1448 cwnd:169 bytes_sent:6134751 bytes_retrans:2575 bytes_acked:6038937 bytes_received:62369 segs_out:4584 segs_in:2850 data_segs_out:4491 data_segs_in:180 bbr:(bw:5.1Mbps,mrtt:117.134,pacing_gain:2.88672,cwnd_gain:2.88672) send 5.1Mbps lastsnd:4 lastrcv:92 lastack:4 pacing_rate 14.6Mbps delivery_rate 5.1Mbps delivered:4424 app_limited busy:33848ms sndbuf_limited:244ms(0.7%) unacked:68 retrans:0/2 dsack_dups:2 reordering:33 reord_seen:720 rcv_rtt:145 rcv_space:14600 rcv_ssthresh:64076 minrtt:112.477

======================================================================
```

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
