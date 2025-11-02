import std/[osproc, nre, times, os, strformat]
import db_connector/db_sqlite
import strutils
from parseopt import CmdLineKind, initOptParser, next



const
  COMMAND = "ss -mito"
  TIME_FORMAT = "yyyy-MM-dd - H:mm:ss"
  LOG_PATH = "/var/log/qwatcher.log"
  DB_PATH = "/var/log/qwatcher.db"
  TEN_SECONDS = 10000
  VERSION = "0.3.0"


type Queue = object
  state: string
  recvQ: string
  sendQ: string
  localAddr: string
  localPort: string
  peerAddr: string
  peerPort: string
  process: string
  info: string


type
  Flags = tuple[
    sendQ: int,
    recvQ: int,
    refresh: int,
    dbPath: string,
    logPath: string,
    stdout: bool
  ]


proc usage(exitCode: int = 0) =
  echo """

  --recv_q,   INT               : Minimum Receive Queue in bytes to trigger a report (default: 10000)
  --send_q,   INT               : Minimum Send Queue in bytes to trigger a report (default: 10000)
  --refresh,  INT               : Refresh interval in seconds (default: 10)
  --db_path,  STRING            : Path to create an SQLite database to log reports (default: /var/log/qwatcher.db)
  --log_path, STRING (Optional) : Path to log file to write reports (default: /var/log/qwatcher.log)
  --stdout,   BOOL              : Output reports only to the stdout
  -h, --help                    : show help
  -v, --version,                : Show version

  For instance:

  qwatcher --recv_q:100000 --send_q:100000 --db_path:/var/log/qwatcher.db
  qwatcher --recv_q:100000 --send_q:100000 --log_path:/var/log/qwatcher.log
  qwatcher --recv_q:100000 --send_q:100000 --stdout:true

  """
  quit(exitCode)


proc getArgs(): Flags =
  var flags: Flags = (sendQ: 10000,
                      recvQ: 10000,
                      refresh: TEN_SECONDS,
                      dbPath: "",
                      logPath: "",
                      stdout: false
  )

  var p = initOptParser()

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdLongOption, cmdShortOption:
      case p.key
      of "help", "h": usage()
      of "version", "v": echo "Version: ", VERSION; quit()
      of "recv_q": flags.recvQ = if p.val == "": 10000 else: parseInt(p.val)
      of "send_q": flags.sendQ = if p.val == "": 10000 else: parseInt(p.val)
      of "refresh": flags.refresh = if p.val == "": TEN_SECONDS else: parseInt(p.val)
      of "db_path": flags.dbPath = p.val
      of "log_path": flags.logPath = p.val
      of "stdout": flags.stdout = parseBool(p.val)
    of cmdArgument: discard
    next(p)

  if flags.dbPath == "" and flags.logPath == "":
    echo "Specify either db_path or log_path flags"
    usage(1)

  if flags.stdout and flags.dbPath.len() != 0 or flags.logPath.len() != 0:
    flags.dbPath = ""

  if not flags.stdout and flags.dbPath.len() != 0 and flags.logPath.len() != 0:
    echo "Specify one of --db_path, --log_path or --stdout flags"
    usage(1)

  echo "Starting with flags: ", $flags

  return flags


proc ensureCommandExists() =
  let result = findExe("ss")
  if result == "": quit("ss command not found", 1)


proc getCurrentTime(): string =
  now().format(TIME_FORMAT)


proc formatAndSplit(s: var string): seq[string] =
  s.strip().replace(re"\s+", " ").split(" ")


proc execCommand(command: string): seq[string] =
  osproc.execProcess(command = COMMAND).splitLines()


proc getReport(queue: Queue): string =
  let delim = "=".repeat(70)
  var report = ""

  report.add(&"{delim}\n")
  report.add(&"Time:\t\t{getCurrentTime()}\n")
  report.add(&"State:\t\t{queue.state}\n")
  report.add(&"Receive-Q:\t{queue.recvQ}\n")
  report.add(&"Send-Q:\t\t{queue.sendQ}\n")
  report.add(&"Local Address:\t{queue.localAddr}:{queue.localPort}\n")
  report.add(&"Remote Address:\t{queue.peerAddr}:{queue.peerPort}\n")
  report.add(&"Process:\t{queue.process}\n\n")
  report.add(&"Info:\t{queue.info}\n\n")
  report.add(&"{delim}\n")

  return report


proc logReportToFile(queue: var Queue, logFileName: string) =
  let report = getReport(queue)

  let logFile = open(logFileName, fmAppend)
  defer: logFile.close()

  logFile.writeLine(report)


proc logReportToDatabase(queue: var Queue, databaseName: string) =
  let db = open(databaseName, "", "", "")

  db.exec(sql"""CREATE TABLE IF NOT EXISTS qwatcher
                (
                  id    INTEGER PRIMARY KEY,
                  time  TEXT NOT NULL,
                  state TEXT NOT NULL,
                  receiveQ TEXT NOT NULL,
                  sendQ TEXT NOT NULL,
                  localAddress TEXT NOT NULL,
                  remoteAddress TEXT NOT NULL,
                  process TEXT NOT NULL,
                  info TEXT NOT NULL
                )"""
    )

  db.exec(sql"BEGIN")

  db.exec(sql"""INSERT INTO qwatcher
                (
                  time,
                  state,
                  receiveQ,
                  sendQ,
                  localAddress,
                  remoteAddress,
                  process,
                  info
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                getCurrentTime(),
                queue.state,
                queue.recvQ,
                queue.sendQ,
                queue.localAddr & ":" & queue.localPort,
                queue.peerAddr & ":" & queue.peerPort,
                queue.process,
                queue.info
  )

  db.exec(sql"COMMIT")
  db.close()


proc displayReport(queue: var Queue) =
  echo getReport(queue)


proc generateReport(line: var seq[string], additionalInfo: var string): Queue =
  if len(line) < 5: quit(fmt"Cannot process `ss` output: {line}", 1)

  var queue: Queue

  queue.state = line[0]
  queue.recvQ = line[1]
  queue.sendQ = line[2]
  queue.localAddr = line[3].split(":")[0]
  queue.localPort = line[3].split(":")[1]
  queue.peerAddr = line[4].split(":")[0]
  queue.peerPort = line[4].split(":")[1]

  if len(line) > 5:
    queue.process = line[5]
  else:
    queue.process = "No process"

  queue.info = additionalInfo.strip()

  return queue


proc main() =
  ensureCommandExists()
  let args = getArgs()

  while true:
    let result = execCommand(COMMAND)

    for item in countup(1, len(result) - 2, 2):
      var line = result[item]
      var formattedLine = formatAndSplit(line)
      var additionalInfo = result[item + 1]
      var generatedReport = generateReport(formattedLine, additionalInfo)

      if parseint(generatedReport.recvQ) >= args.recvQ or
          parseint(generatedReport.sendQ) >= args.sendQ:
        if args.dbPath.len != 0:
          logReportToDatabase(generatedReport, args.dbPath)
        elif args.logPath.len != 0:
          logReportToFile(generatedReport, args.logPath)
        else:
          displayReport(generatedReport)

    sleep args.refresh


when is_main_module:
  main()
