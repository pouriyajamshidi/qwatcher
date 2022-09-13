import std/[osproc, nre, times, os, strformat, parseopt, db_sqlite]
import strutils



const
  COMMAND = "ss -mito"
  TIME_FORMAT = "yyyy-MM-dd - H:mm:ss"
  LOG_FILE = "/var/log/qwatcher.log"
  DB_FILE = "/var/log/qwatcher.db"
  TEN_SECONDS = 10000
  VERSION = "0.2.0"


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


proc usage() =
  echo """

  -h, --help        : show help
  --recv_q,  INT    : Minimum receive-Q to trigger alert in bytes (default: 10000)
  --send_q,  INT    : Minimum send-Q to trigger alert in bytes (default: 10000)
  --refresh, INT    : Refresh interval in seconds (default: 10)
  --db_path,        : Path to SQLite database to log reports (default: /var/log/qwatcher.db)
  --log_path,       : Path to log file to log reports (default: /var/log/qwatcher.log)
  -v, --version,    : Show version

  """
  quit()


proc ensureCommandExists() =
  let result = findExe("ss")
  if result == "": quit("ss command not found", 1)


proc getArgs(): tuple =
  var flags: tuple[
        sendQ: int,
        recvQ: int,
        refresh: int,
        db: tuple[isSet: bool, path: string],
        log: tuple[isSet: bool, path: string]
    ]

  var p = initOptParser(commandLineParams())

  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": usage()
      of "version", "v": echo "Version: ", VERSION; quit()
      if p.key == "recv_q" and p.val == "":
        flags.recvQ = 10000
      elif p.key == "recv_q":
        flags.recvQ = parseInt(p.val)
      if p.key == "send_q" and p.val == "":
        flags.sendQ = 10000
      elif p.key == "send_q":
        flags.sendQ = parseInt(p.val)
      if p.key == "refresh" and p.val == "":
        flags.refresh = TEN_SECONDS
      elif p.key == "refresh" and parseInt(p.val) == 0:
        echo "Refresh interval must be greater than 0. Defaulting to 10 seconds"
      elif p.key == "refresh":
        flags.refresh = parseInt(p.val)
      if p.key == "db_path":
        flags.db.isSet = true
        flags.db.path = p.val
      if p.key == "log_path":
        flags.log.isSet = true
        flags.log.path = p.val
    of cmdEnd: break
    of cmdArgument: discard

  if flags.refresh <= 0: flags.refresh = TEN_SECONDS
  if flags.sendQ == 0: flags.sendQ = 10000
  if flags.recvQ == 0: flags.recvQ = 10000
  if flags.db.isSet and flags.db.path == "":
    flags.db.path = DB_FILE
  if flags.log.isSet and flags.log.path == "":
    flags.log.path = LOG_FILE

  return flags


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
  if len(line) < 5: quit("Cannot process `ss` output", 1)

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
        if args.db.isSet:
          logReportToDatabase(generatedReport, args.db.path)
        elif args.log.isSet:
          logReportToFile(generatedReport, args.log.path)
        else:
          displayReport(generatedReport)

    sleep args.refresh


when is_main_module:
  main()
