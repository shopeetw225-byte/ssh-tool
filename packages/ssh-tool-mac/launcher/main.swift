import AppKit
import Foundation

func stderr(_ message: String) {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func bashSingleQuoted(_ s: String) -> String {
  // ' -> '\'' (close, escape, reopen)
  return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func fileExists(_ path: String) -> Bool {
  FileManager.default.fileExists(atPath: path)
}

func makeTempCommandFile(contents: String) throws -> URL {
  let fileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("ssh-tool-\(UUID().uuidString).command")

  try contents.write(to: fileURL, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
  return fileURL
}

enum Action: String {
  case start
  case stop
  case recover
  case status
}

let args = Array(CommandLine.arguments.dropFirst())
let requestedAction = args.first.flatMap { Action(rawValue: $0.lowercased()) }

let statePath = ProcessInfo.processInfo.environment["SSH_TOOL_STATE_PATH"] ?? "/var/tmp/ssh-tool/active-session.json"
let inferredAction: Action = fileExists(statePath) ? .stop : .start
let action = requestedAction ?? inferredAction

guard let resourcesURL = Bundle.main.resourceURL else {
  stderr("Missing app resources.")
  exit(1)
}

let toolDir = resourcesURL.appendingPathComponent("ssh-tool-mac", isDirectory: true)
let toolDirPath = toolDir.path

if !fileExists(toolDirPath) {
  stderr("Missing ssh-tool-mac resources folder: \(toolDirPath)")
  exit(1)
}

let actionScript: String
switch action {
case .start:
  actionScript = "./remote-support.sh start"
case .stop:
  actionScript = """
if ! ./remote-support.sh stop; then
  ./remote-support.sh recover
fi
"""
case .recover:
  actionScript = "./remote-support.sh recover"
case .status:
  actionScript = """
./remote-support.sh status || true
echo
read -n 1 -s -r -p "Press any key to close..." || true
echo
"""
}

let cmdFileContents = """
#!/bin/bash
set -Eeuo pipefail
trap 'rm -f "$0"' EXIT

cd \(bashSingleQuoted(toolDirPath))
chmod +x ./remote-support.sh ./bore ./bore-arm64 ./bore-x86_64 2>/dev/null || true

\(actionScript)
"""

do {
  let cmdURL = try makeTempCommandFile(contents: cmdFileContents)
  NSWorkspace.shared.open(cmdURL)
} catch {
  stderr("Failed to launch Terminal command: \(error)")
  exit(1)
}

