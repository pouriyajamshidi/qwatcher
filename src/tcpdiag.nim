import std/[posix, strformat, strutils]

type
  Conn* = object
    state*: string
    recvQ*: int
    sendQ*: int
    localAddr*: string
    localPort*: int
    peerAddr*: string
    peerPort*: int
    inode*: uint32
    info*: string
    process*: string

  TcpDiagError* = object of CatchableError

const
  AF_NETLINK = 16.cint
  NETLINK_SOCK_DIAG = 4.cint
  SOCK_DIAG_BY_FAMILY = 20'u16
  NLM_F_REQUEST = 0x0001'u16
  NLM_F_DUMP = 0x0300'u16
  NLMSG_ERROR = 2'u16
  NLMSG_DONE = 3'u16
  INET_DIAG_INFO = 2'u16
  INET_DIAG_SKMEMINFO = 7'u16
  IPPROTO_TCP_U8 = 6'u8
  RECV_BUF_SIZE = 64 * 1024

  # ss's default filter: every state except LISTEN and CLOSE.
  DIAG_STATES = 0xFFF'u32 and not (1'u32 shl 10) and not (1'u32 shl 7)

  STATE_NAMES = ["UNKNOWN", "ESTAB", "SYN-SENT", "SYN-RECV", "FIN-WAIT-1",
                 "FIN-WAIT-2", "TIME-WAIT", "UNCONN", "CLOSE-WAIT",
                 "LAST-ACK", "LISTEN", "CLOSING"]

type
  NlMsgHdr = object
    len: uint32
    kind: uint16
    flags: uint16
    seqNo: uint32
    pid: uint32

  SockaddrNl = object
    family: uint16
    pad: uint16
    pid: uint32
    groups: uint32

  RtAttr = object
    len: uint16
    kind: uint16

  InetDiagSockId = object
    sport: uint16
    dport: uint16
    src: array[4, uint32]
    dst: array[4, uint32]
    ifIdx: uint32
    cookie: array[2, uint32]

  InetDiagReqV2 = object
    family: uint8
    protocol: uint8
    ext: uint8
    pad: uint8
    states: uint32
    id: InetDiagSockId

  InetDiagMsg = object
    family: uint8
    state: uint8
    timer: uint8
    retrans: uint8
    id: InetDiagSockId
    expires: uint32
    rqueue: uint32
    wqueue: uint32
    uid: uint32
    inode: uint32

  TcpInfo = object
    state: uint8
    caState: uint8
    retransmits: uint8
    probes: uint8
    backoff: uint8
    options: uint8
    wscale: uint8
    appLimited: uint8
    rto: uint32
    ato: uint32
    sndMss: uint32
    rcvMss: uint32
    unacked: uint32
    sacked: uint32
    lost: uint32
    retrans: uint32
    fackets: uint32
    lastDataSent: uint32
    lastAckSent: uint32
    lastDataRecv: uint32
    lastAckRecv: uint32
    pmtu: uint32
    rcvSsthresh: uint32
    rtt: uint32
    rttvar: uint32
    sndSsthresh: uint32
    sndCwnd: uint32
    advmss: uint32
    reordering: uint32
    rcvRtt: uint32
    rcvSpace: uint32
    totalRetrans: uint32
    pacingRate: uint64
    maxPacingRate: uint64
    bytesAcked: uint64
    bytesReceived: uint64
    segsOut: uint32
    segsIn: uint32
    notsentBytes: uint32
    minRtt: uint32

  DiagRequest = object
    hdr: NlMsgHdr
    req: InetDiagReqV2

static:
  doAssert sizeof(NlMsgHdr) == 16
  doAssert sizeof(InetDiagSockId) == 48
  doAssert sizeof(InetDiagReqV2) == 56
  doAssert sizeof(InetDiagMsg) == 72

template align4(n: int): int = (n + 3) and not 3

proc beToPort(v: uint16): int =
  int((v shr 8) or (v shl 8))

proc ipToString(family: uint8, words: array[4, uint32]): string =
  var buf: array[46, char]
  let af = if family == uint8(AF_INET6): AF_INET6 else: AF_INET
  if inet_ntop(af, cast[pointer](unsafeAddr words[0]), cast[cstring](addr buf[0]),
               int32(buf.len)) == nil:
    return ""
  $cast[cstring](addr buf[0])

proc formatInfo(tcp: TcpInfo, hasTcp: bool, skmem: array[9, uint32],
                hasSkmem: bool): string =
  var parts: seq[string]

  if hasSkmem:
    parts.add &"skmem:(r{skmem[0]},rb{skmem[1]},t{skmem[2]},tb{skmem[3]})"

  if hasTcp:
    if tcp.rto > 0:
      parts.add &"rto:{tcp.rto div 1000}"
    parts.add &"rtt:{tcp.rtt.float / 1000.0:.3f}/{tcp.rttvar.float / 1000.0:.3f}"
    if tcp.minRtt > 0:
      parts.add &"minrtt:{tcp.minRtt.float / 1000.0:.3f}"
    parts.add &"mss:{tcp.sndMss}"
    parts.add &"cwnd:{tcp.sndCwnd}"
    if tcp.totalRetrans > 0:
      parts.add &"retrans:{tcp.retrans}/{tcp.totalRetrans}"

  parts.join(" ")

proc parseAttrs(buf: openArray[byte], start, stop: int): string =
  var tcp: TcpInfo
  var skmem: array[9, uint32]
  var hasTcp = false
  var hasSkmem = false
  var off = start

  while off + sizeof(RtAttr) <= stop:
    let rta = cast[ptr RtAttr](unsafeAddr buf[off])
    let rlen = int(rta.len)
    if rlen < sizeof(RtAttr) or off + rlen > stop: break

    let payload = off + sizeof(RtAttr)
    let payloadLen = rlen - sizeof(RtAttr)

    case rta.kind
    of INET_DIAG_INFO:
      if payloadLen > 0:
        copyMem(addr tcp, unsafeAddr buf[payload], min(payloadLen, sizeof(TcpInfo)))
        hasTcp = true
    of INET_DIAG_SKMEMINFO:
      if payloadLen > 0:
        copyMem(addr skmem, unsafeAddr buf[payload], min(payloadLen, sizeof(skmem)))
        hasSkmem = true
    else: discard

    off += align4(rlen)

  formatInfo(tcp, hasTcp, skmem, hasSkmem)

proc toConn(msg: ptr InetDiagMsg, info: string): Conn =
  let stateIdx = int(msg.state)
  Conn(
    state: if stateIdx < STATE_NAMES.len: STATE_NAMES[stateIdx] else: "UNKNOWN",
    recvQ: int(msg.rqueue),
    sendQ: int(msg.wqueue),
    localAddr: ipToString(msg.family, msg.id.src),
    localPort: beToPort(msg.id.sport),
    peerAddr: ipToString(msg.family, msg.id.dst),
    peerPort: beToPort(msg.id.dport),
    inode: msg.inode,
    info: info,
  )

proc sendRequest(fd: SocketHandle, family: uint8, seqNo: uint32) =
  var req = DiagRequest(
    hdr: NlMsgHdr(
      len: uint32(sizeof(DiagRequest)),
      kind: SOCK_DIAG_BY_FAMILY,
      flags: NLM_F_REQUEST or NLM_F_DUMP,
      seqNo: seqNo,
      pid: 0,
    ),
    req: InetDiagReqV2(
      family: family,
      protocol: IPPROTO_TCP_U8,
      ext: uint8((1 shl (INET_DIAG_INFO - 1)) or (1 shl (INET_DIAG_SKMEMINFO - 1))),
      states: DIAG_STATES,
    ),
  )

  var dest = SockaddrNl(family: uint16(AF_NETLINK))
  let sent = sendto(fd, addr req, sizeof(req), 0.cint,
                    cast[ptr SockAddr](addr dest), SockLen(sizeof(dest)))
  if sent != sizeof(req):
    raise newException(TcpDiagError, "netlink request failed: " & $strerror(errno))

proc collect(fd: SocketHandle, seqNo: uint32, conns: var seq[Conn]) =
  var buf = newSeq[byte](RECV_BUF_SIZE)
  var src: SockaddrNl
  var srcLen = SockLen(sizeof(src))

  while true:
    let n = recvfrom(fd, addr buf[0], buf.len, 0,
                     cast[ptr SockAddr](addr src), addr srcLen)
    if n < 0:
      if errno == EINTR: continue
      raise newException(TcpDiagError, "netlink recv failed: " & $strerror(errno))
    if n == 0:
      return

    # Only the kernel (port id 0, no multicast group) may answer us.
    if src.pid != 0 or src.groups != 0:
      continue

    var off = 0
    while off + sizeof(NlMsgHdr) <= n:
      let hdr = cast[ptr NlMsgHdr](addr buf[off])
      let mlen = int(hdr.len)
      if mlen < sizeof(NlMsgHdr) or off + mlen > n:
        raise newException(TcpDiagError, "malformed netlink message")

      if hdr.seqNo != seqNo:
        off += align4(mlen)
        continue

      case hdr.kind
      of NLMSG_DONE:
        return
      of NLMSG_ERROR:
        var code: int32
        if mlen >= sizeof(NlMsgHdr) + sizeof(int32):
          copyMem(addr code, addr buf[off + sizeof(NlMsgHdr)], sizeof(int32))
        raise newException(TcpDiagError,
                           "netlink error: " & $strerror(-code))
      of SOCK_DIAG_BY_FAMILY:
        if mlen >= sizeof(NlMsgHdr) + sizeof(InetDiagMsg):
          let body = off + sizeof(NlMsgHdr)
          let msg = cast[ptr InetDiagMsg](addr buf[body])
          let info = parseAttrs(buf, body + sizeof(InetDiagMsg), off + mlen)
          conns.add toConn(msg, info)
      else: discard

      off += align4(mlen)

proc queryTcp*(): seq[Conn] =
  ## Asks the kernel for TCP sockets over NETLINK_SOCK_DIAG, the same
  ## interface `ss` uses.
  let fd = socket(AF_NETLINK, posix.SOCK_DGRAM, NETLINK_SOCK_DIAG)
  if fd == INVALID_SOCKET:
    raise newException(TcpDiagError, "cannot open netlink socket: " &
                       $strerror(errno))
  defer: discard close(fd)

  var src = SockaddrNl(family: uint16(AF_NETLINK))
  if bindSocket(fd, cast[ptr SockAddr](addr src), SockLen(sizeof(src))) != 0:
    raise newException(TcpDiagError, "cannot bind netlink socket: " &
                       $strerror(errno))

  for i, family in [uint8(AF_INET), uint8(AF_INET6)]:
    let seqNo = uint32(i + 1)
    sendRequest(fd, family, seqNo)
    collect(fd, seqNo, result)
