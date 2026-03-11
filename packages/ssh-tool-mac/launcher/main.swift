import AppKit
import Carbon
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

func parseMinutes(_ s: String?) -> Int? {
  guard let raw = s?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
  guard let v = Int(raw) else { return nil }
  if v < 1 { return 1 }
  if v > 1440 { return 1440 }
  return v
}

func actionFromURL(_ url: URL) -> (Action, Int?)? {
  let token: String? = {
    if let host = url.host, !host.isEmpty { return host }
    let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if trimmedPath.isEmpty { return nil }
    return trimmedPath.split(separator: "/").first.map(String.init)
  }()

  let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
  let minutes = parseMinutes(components?.queryItems?.first { $0.name.lowercased() == "minutes" }?.value)

  switch token?.lowercased() {
  case "start": return (.start, minutes)
  case "stop": return (.stop, nil)
  case "recover": return (.recover, nil)
  case "status": return (.status, nil)
  default: return nil
  }
}

final class Runner {
  let toolDirPath: String

  init(toolDirPath: String) {
    self.toolDirPath = toolDirPath
  }

  func run(action: Action, minutes: Int?) throws {
    let actionScript: String
    switch action {
    case .start:
      if let minutes {
        actionScript = "SSH_TOOL_MINUTES=\(minutes) ./remote-support.sh start"
      } else {
        actionScript = "./remote-support.sh start"
      }
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

    let cmdURL = try makeTempCommandFile(contents: cmdFileContents)
    NSWorkspace.shared.open(cmdURL)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  let runner: Runner
  let statePath: String
  let requestedAction: Action?
  let requestedMinutes: Int?

  private var didRun = false

  init(runner: Runner, statePath: String, requestedAction: Action?, requestedMinutes: Int?) {
    self.runner = runner
    self.statePath = statePath
    self.requestedAction = requestedAction
    self.requestedMinutes = requestedMinutes
    super.init()

    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      self?.runDefaultIfNeeded()
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      if self.run(fromURL: url) { return }
    }
  }

  @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
    guard
      let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
      let url = URL(string: urlString)
    else {
      return
    }
    _ = self.run(fromURL: url)
  }

  private func run(fromURL url: URL) -> Bool {
    guard let (action, minutes) = actionFromURL(url) else { return false }
    self.runIfNeeded(action: action, minutes: minutes)
    return true
  }

  private func runDefaultIfNeeded() {
    if let requestedAction {
      self.runIfNeeded(action: requestedAction, minutes: requestedMinutes)
      return
    }

    let inferredAction: Action = fileExists(statePath) ? .stop : .start
    self.runIfNeeded(action: inferredAction, minutes: nil)
  }

  private func runIfNeeded(action: Action, minutes: Int?) {
    if didRun { return }
    didRun = true

    do {
      try runner.run(action: action, minutes: minutes)
    } catch {
      stderr("Failed to launch Terminal command: \(error)")
    }

    NSApp.terminate(nil)
  }
}

let args = Array(CommandLine.arguments.dropFirst())

let requestedAction: Action? = {
  for arg in args {
    if let a = Action(rawValue: arg.lowercased()) { return a }
  }
  return nil
}()

let requestedMinutes: Int? = {
  guard requestedAction == .start else { return nil }
  guard let idx = args.firstIndex(where: { $0 == "--minutes" || $0 == "-m" }) else { return nil }
  guard idx + 1 < args.count else { return nil }
  return parseMinutes(args[idx + 1])
}()

let statePath = ProcessInfo.processInfo.environment["SSH_TOOL_STATE_PATH"] ?? "/var/tmp/ssh-tool/active-session.json"

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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let runner = Runner(toolDirPath: toolDirPath)
let delegate = AppDelegate(runner: runner, statePath: statePath, requestedAction: requestedAction, requestedMinutes: requestedMinutes)
app.delegate = delegate
app.run()
