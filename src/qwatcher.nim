import std/[os, posix, sets, strformat, strutils, tables, times]
import db_connector/db_sqlite
import tcpdiag

from parseopt import CmdLineKind, initOptParser, next

const
  VERSION = "0.5.0"
  TIME_FORMAT = "yyyy-MM-dd'T'HH:mm:ss"
  DEFAULT_QUEUE = 10_000
  DEFAULT_REFRESH = 5
  DEFAULT_LIMIT = 20
  DELIM = "=".repeat(70)
  OWNER_ONLY = {fpUserRead, fpUserWrite}

  SCHEMA = sql"""
    CREATE TABLE IF NOT EXISTS qwatcher (
      id            INTEGER PRIMARY KEY,
      time          TEXT    NOT NULL,
      state         TEXT    NOT NULL,
      receiveQ      INTEGER NOT NULL,
      sendQ         INTEGER NOT NULL,
      localAddress  TEXT    NOT NULL,
      localPort     INTEGER NOT NULL,
      remoteAddress TEXT    NOT NULL,
      remotePort    INTEGER NOT NULL,
      process       TEXT    NOT NULL,
      info          TEXT    NOT NULL
    )"""

  INSERT_REPORT = """
    INSERT INTO qwatcher
      (time, state, receiveQ, sendQ, localAddress, localPort,
       remoteAddress, remotePort, process, info)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"""

type
  OutputKind = enum
    toStdout, toFile, toDatabase

  Flags = object
    recvQ: int
    sendQ: int
    refresh: int
    limit: int
    path: string
    output: OutputKind
    report: bool
    follow: bool

var running = true


proc usage(exitCode: int = 0) =
  echo """
  --recv_q,   INT    : Minimum Receive Queue in bytes to trigger a report (default: 10000)
  --send_q,   INT    : Minimum Send Queue in bytes to trigger a report (default: 10000)
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

  qwatcher --recv_q:100000 --send_q:100000 --db_path:/var/log/qwatcher.db
  qwatcher --recv_q:100000 --send_q:100000 --log_path:/var/log/qwatcher.log
  qwatcher --recv_q:100000 --send_q:100000 --stdout

  qwatcher --db_path:/var/log/qwatcher.db --report
  qwatcher --db_path:/var/log/qwatcher.db --report --limit:100
  qwatcher --db_path:/var/log/qwatcher.db --follow
"""
  quit(exitCode)


proc fail(message: string) =
  stderr.writeLine message
  usage(1)


proc positiveInt(key, value: string, fallback: int): int =
  if value.len == 0:
    return fallback
  try:
    result = parseInt(value)
  except ValueError:
    fail(&"--{key} expects a number, got '{value}'")
  if result <= 0:
    fail(&"--{key} must be greater than zero")


proc boolFlag(key, value: string): bool =
  if value.len == 0:
    return true
  try:
    result = parseBool(value)
  except ValueError:
    fail(&"--{key} expects true or false, got '{value}'")


proc getArgs(): Flags =
  result = Flags(recvQ: DEFAULT_QUEUE, sendQ: DEFAULT_QUEUE,
                 refresh: DEFAULT_REFRESH, limit: DEFAULT_LIMIT,
                 output: toStdout)

  var dbPath, logPath: string
  var explicitStdout = false
  var parser = initOptParser()

  while true:
    parser.next()
    case parser.kind
    of cmdEnd: break
    of cmdLongOption, cmdShortOption:
      case parser.key
      of "help", "h": usage()
      of "version", "v": echo "Version: ", VERSION; quit()
      of "recv_q": result.recvQ = positiveInt(parser.key, parser.val, DEFAULT_QUEUE)
      of "send_q": result.sendQ = positiveInt(parser.key, parser.val, DEFAULT_QUEUE)
      of "refresh": result.refresh = positiveInt(parser.key, parser.val, DEFAULT_REFRESH)
      of "db_path": dbPath = parser.val
      of "log_path": logPath = parser.val
      of "stdout": explicitStdout = boolFlag(parser.key, parser.val)
      of "report": result.report = boolFlag(parser.key, parser.val)
      of "limit": result.limit = positiveInt(parser.key, parser.val, DEFAULT_LIMIT)
      of "follow": result.follow = boolFlag(parser.key, parser.val)
      else: fail(&"Unknown flag: {parser.key}")
    of cmdArgument: fail(&"Unexpected argument: {parser.key}")

  if dbPath.len != 0 and logPath.len != 0:
    fail("Specify only one of --db_path or --log_path")
  if explicitStdout and (dbPath.len != 0 or logPath.len != 0):
    fail("--stdout cannot be combined with --db_path or --log_path")

  if result.follow:
    result.report = true

  if result.report and dbPath.len == 0:
    fail("--report and --follow need --db_path to read from")

  if dbPath.len != 0:
    result.output = toDatabase
    result.path = dbPath
  elif logPath.len != 0:
    result.output = toFile
    result.path = logPath


proc currentTime(): string =
  now().format(TIME_FORMAT)


proc endpoint(address: string, port: int): string =
  if ':' in address: &"[{address}]:{port}" else: &"{address}:{port}"


proc report(conn: Conn, timestamp: string): string =
  &"""{DELIM}
Time:           {timestamp}
State:          {conn.state}
Receive-Q:      {conn.recvQ}
Send-Q:         {conn.sendQ}
Local Address:  {endpoint(conn.localAddr, conn.localPort)}
Remote Address: {endpoint(conn.peerAddr, conn.peerPort)}
Process:        {conn.process}
Info:           {conn.info}
{DELIM}"""


const REPORT_COLUMNS = """
  id, time, state, receiveQ, sendQ, localAddress, localPort,
  remoteAddress, remotePort, process, info"""


proc rowToReport(row: Row): string =
  report(Conn(
    state: row[2],
    recvQ: parseInt(row[3]),
    sendQ: parseInt(row[4]),
    localAddr: row[5],
    localPort: parseInt(row[6]),
    peerAddr: row[7],
    peerPort: parseInt(row[8]),
    process: row[9],
    info: row[10],
  ), row[1])


proc printReports(path: string, limit, refresh: int, follow: bool) =
  if not fileExists(path):
    quit(&"No database at {path}", 1)

  let db = open(path, "", "", "")
  defer: db.close()

  var recent: seq[Row]
  for row in db.fastRows(sql("SELECT " & REPORT_COLUMNS &
                             " FROM qwatcher ORDER BY id DESC LIMIT ?"), limit):
    recent.add row

  if recent.len == 0 and not follow:
    echo "No reports stored in ", path
    return

  for i in countdown(recent.high, 0):
    echo rowToReport(recent[i])

  if not follow:
    return

  var lastId = if recent.len > 0: parseInt(recent[0][0]) else: 0
  let newer = sql("SELECT " & REPORT_COLUMNS &
                  " FROM qwatcher WHERE id > ? ORDER BY id ASC")

  while running:
    for _ in 1 .. refresh:
      if not running: break
      sleep 1000

    for row in db.fastRows(newer, lastId):
      if not running: break
      echo rowToReport(row)
      lastId = parseInt(row[0])


proc processesByInode(wanted: HashSet[uint32]): Table[uint32, string] =
  ## Maps the given socket inodes to the process holding them, giving up as soon
  ## as all of them are found. Only readable for processes we own, so running as
  ## root gives the full picture.
  for kind, pidPath in walkDir("/proc"):
    if kind != pcDir: continue

    let pid = pidPath.lastPathPart
    if pid.len == 0 or not pid.allCharsInSet(Digits): continue

    var name = ""
    try:
      for _, fdPath in walkDir(pidPath / "fd"):
        var target: string
        try:
          target = expandSymlink(fdPath)
        except OSError:
          continue

        if not target.startsWith("socket:[") or not target.endsWith("]"):
          continue

        var inode: uint32
        try:
          inode = uint32(parseUInt(target["socket:[".len ..< target.high]))
        except ValueError:
          continue

        if inode notin wanted: continue

        if name.len == 0:
          name = try: readFile(pidPath / "comm").strip() except CatchableError: pid
        result[inode] = &"{name}(pid={pid},fd={fdPath.lastPathPart})"
        if result.len == wanted.len: return
    except OSError:
      discard


proc openDatabase(path: string): DbConn =
  result = open(path, "", "", "")
  # WAL keeps readers (sqlite3, dashboards) from blocking the writer, and lets
  # NORMAL synchronous skip an fsync per commit without risking corruption.
  result.exec(sql"PRAGMA journal_mode = WAL")
  result.exec(sql"PRAGMA synchronous = NORMAL")
  result.exec(sql"PRAGMA busy_timeout = 5000")
  result.exec(SCHEMA)
  result.exec(sql"CREATE INDEX IF NOT EXISTS qwatcher_time_idx ON qwatcher(time)")
  setFilePermissions(path, OWNER_ONLY)


proc writeToDatabase(db: DbConn, statement: SqlPrepared, conns: seq[Conn],
                     timestamp: string) =
  db.exec(sql"BEGIN")
  try:
    for conn in conns:
      db.exec(statement, timestamp, conn.state, conn.recvQ, conn.sendQ,
              conn.localAddr, conn.localPort, conn.peerAddr, conn.peerPort,
              conn.process, conn.info)
    db.exec(sql"COMMIT")
  except DbError:
    db.exec(sql"ROLLBACK")
    raise


proc writeToFile(path: string, conns: seq[Conn], timestamp: string) =
  let file = open(path, fmAppend)
  defer: file.close()
  setFilePermissions(path, OWNER_ONLY)
  for conn in conns:
    file.writeLine report(conn, timestamp)


proc writeToStdout(conns: seq[Conn], timestamp: string) =
  for conn in conns:
    echo report(conn, timestamp)


proc main() =
  let args = getArgs()

  onSignal(SIGINT, SIGTERM):
    running = false

  if args.report:
    printReports(args.path, args.limit, args.refresh, args.follow)
    return

  var db: DbConn
  var statement: SqlPrepared
  if args.output == toDatabase:
    db = openDatabase(args.path)
    statement = db.prepare(INSERT_REPORT)

  while running:
    var breached: seq[Conn]
    var wanted: HashSet[uint32]

    for conn in queryTcp():
      if conn.recvQ < args.recvQ and conn.sendQ < args.sendQ:
        continue
      breached.add conn
      # Orphaned sockets report inode 0 and can never be traced to a process.
      if conn.inode != 0:
        wanted.incl conn.inode

    if breached.len != 0:
      let processes = processesByInode(wanted)
      for conn in breached.mitems:
        conn.process = processes.getOrDefault(conn.inode, "No process")

      let timestamp = currentTime()
      case args.output
      of toDatabase: writeToDatabase(db, statement, breached, timestamp)
      of toFile: writeToFile(args.path, breached, timestamp)
      of toStdout: writeToStdout(breached, timestamp)

    for _ in 1 .. args.refresh:
      if not running: break
      sleep 1000

  if args.output == toDatabase:
    statement.finalize()
    db.close()


when isMainModule:
  try:
    main()
  except TcpDiagError, DbError, IOError, OSError, ValueError:
    stderr.writeLine getCurrentExceptionMsg()
    quit(1)
