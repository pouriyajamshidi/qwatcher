import std/[osproc, nre, times, os, strformat, parseopt]
import strutils



const
  COMMAND = "ss -mito"
  TIME_FORMAT = "yyyy-MM-dd - H:mm:ss"
  LOG_FILE = "/var/log/qwatcher.log"
  TEN_SECONDS = 10000
  VERSION = "0.1.0"


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
  --show_only,      : Show only the current state without logging to file
  -v, --version,    : Show version

  """
  quit()


proc ensureCommandExists() =
  let result = findExe("ss")
  if result == "": quit("ss command not found", 1)


proc getArgs(): tuple =
  var queues: tuple[
        sendQ: int,
        recvQ: int,
        refresh: int,
        showOnly: bool
    ]

  var p = initOptParser(commandLineParams())

  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": usage()
      of "version", "v": echo "Version: ", VERSION; quit()
      if p.key == "recv_q" and p.val == "":
        queues.recvQ = 10000
      elif p.key == "recv_q":
        queues.recvQ = parseInt(p.val)
      if p.key == "send_q" and p.val == "":
        queues.sendQ = 10000
      elif p.key == "send_q":
        queues.sendQ = parseInt(p.val)
      if p.key == "refresh" and p.val == "":
        queues.refresh = TEN_SECONDS
      elif p.key == "refresh" and parseInt(p.val) == 0:
        echo "Refresh interval must be greater than 0. Defaulting to 10 seconds"
      elif p.key == "refresh":
        queues.refresh = parseInt(p.val)
      if p.key == "show_only": queues.showOnly = true
    of cmdEnd: break
    of cmdArgument: discard

  if queues.refresh <= 0: queues.refresh = TEN_SECONDS
  if queues.sendQ == 0: queues.sendQ = 10000
  if queues.recvQ == 0: queues.recvQ = 10000

  return queues


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


proc logReport(queue: var Queue, fileName: string) =
  let report = getReport(queue)

  let logFile = open(fileName, fmAppend)
  defer: logFile.close()

  logFile.writeLine(report)


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
        if args.show_only:
          displayReport(generatedReport)
        else:
          logReport(generatedReport, LOG_FILE)

    sleep args.refresh


when is_main_module:
  main()
