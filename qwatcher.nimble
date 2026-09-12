# Package

version       = "0.5.1"
author        = "Pouriya Jamshidi"
description   = "Linux NIC Buffer Queue Watcher"
license       = "MIT"
srcDir        = "src"
bin           = @["qwatcher"]


# Dependencies

requires "nim >= 2.2.12"
requires "db_connector >= 0.1.0"


# Tasks

task release, "Build an optimized binary and bundle it with the systemd unit":
  let dist = "dist"
  let archive = "qwatcher.tar.gz"

  rmDir dist
  rmFile archive
  mkDir dist

  exec "nimble build -d:release --passL:-s -y"

  # Guard against the binary and the package version drifting apart.
  exec "./qwatcher --version | grep -q " & version

  # cpFile does not preserve the executable bit, so install the binary instead.
  exec "install -m 755 qwatcher " & dist & "/qwatcher"
  for file in ["qwatcher.service", "LICENSE"]:
    cpFile file, dist & "/" & file

  exec "tar -czf " & archive & " -C " & dist & " ."
  rmDir dist

  echo "Created " & archive
