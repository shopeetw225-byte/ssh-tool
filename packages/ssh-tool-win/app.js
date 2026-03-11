const crypto = require("crypto");
const express = require("express");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const app = express();

const PORT = Number.parseInt(process.env.SSH_TOOL_PORT || "", 10) || 3000;
const HOST = process.env.SSH_TOOL_HOST || "127.0.0.1";
const TOKEN =
  (process.env.SSH_TOOL_TOKEN && process.env.SSH_TOOL_TOKEN.trim()) ||
  crypto.randomBytes(24).toString("hex");

const BORE_TO = (process.env.SSH_TOOL_BORE_TO || "bore.pub").trim();
const BORE_LOCAL_PORT = Number.parseInt(process.env.SSH_TOOL_BORE_LOCAL_PORT || "22", 10) || 22;

const MAX_LOG_LINES = 500;
const logLines = [];

function log(level, message) {
  const line = `${new Date().toISOString()} [${level}] ${message}`;
  logLines.push(line);
  if (logLines.length > MAX_LOG_LINES) logLines.shift();
  // eslint-disable-next-line no-console
  console.log(line);
}

function escapeRegExp(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function pickLanIp() {
  const interfaces = os.networkInterfaces();
  const candidates = [];
  for (const name of Object.keys(interfaces)) {
    const lower = name.toLowerCase();
    if (
      lower.includes("vethernet") ||
      lower.includes("docker") ||
      lower.includes("wsl") ||
      lower.includes("vmware") ||
      lower.includes("virtualbox") ||
      lower.includes("loopback")
    ) {
      continue;
    }

    for (const iface of interfaces[name] || []) {
      if (iface.family === "IPv4" && !iface.internal) {
        candidates.push({ name, address: iface.address });
      }
    }
  }

  const preferred = candidates.find(
    (c) => c.address.startsWith("192.168.") || c.address.startsWith("10.")
  );
  return preferred?.address || candidates[0]?.address || "127.0.0.1";
}

function jsonOk(res, payload) {
  res.json({ success: true, ...payload });
}

function jsonErr(res, output, status = 400) {
  res.status(status).json({ success: false, output: String(output || "error") });
}

function requireToken(req, res, next) {
  const got = req.get("x-ssh-tool-token") || "";
  if (got !== TOKEN) return jsonErr(res, "Unauthorized", 401);
  return next();
}

app.use(express.json({ limit: "64kb" }));
app.use("/api", requireToken);
app.use(express.static(path.join(__dirname, "public")));

// ----- PowerShell helpers -----
function runPS(script, { timeoutMs = 60_000 } = {}) {
  return new Promise((resolve) => {
    const encoded = Buffer.from(script, "utf16le").toString("base64");
    const child = spawn(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
      { windowsHide: true }
    );

    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      try {
        child.kill();
      } catch {
        // ignore
      }
    }, timeoutMs);

    child.stdout.on("data", (d) => {
      stdout += d.toString("utf8");
    });
    child.stderr.on("data", (d) => {
      stderr += d.toString("utf8");
    });

    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({ success: false, output: err?.message || String(err), code: null });
    });

    child.on("close", (code) => {
      clearTimeout(timer);
      const output = (stdout || stderr).trim();
      resolve({ success: code === 0, output, code });
    });
  });
}

// ----- Timer state -----
let shutdownTimer = null;
let shutdownAt = null;

function clearTimer() {
  if (shutdownTimer) clearTimeout(shutdownTimer);
  shutdownTimer = null;
  shutdownAt = null;
}

// ----- bore state -----
let boreProcess = null;
let borePublicAddr = null;
let boreLastExit = null;
const boreOutputLines = [];
const MAX_BORE_LINES = 300;

function appendBoreLine(line) {
  const trimmed = String(line).replace(/\r?\n$/, "");
  if (!trimmed) return;
  boreOutputLines.push(`${new Date().toISOString()} ${trimmed}`);
  if (boreOutputLines.length > MAX_BORE_LINES) boreOutputLines.shift();
}

function findBoreBin() {
  const explicit = process.env.SSH_TOOL_BORE_BIN && process.env.SSH_TOOL_BORE_BIN.trim();
  if (explicit) return explicit;

  const local = path.join(__dirname, "bore.exe");
  if (fs.existsSync(local)) return local;

  const bin = path.join(__dirname, "bin", "bore.exe");
  if (fs.existsSync(bin)) return bin;

  return null;
}

function startBore() {
  if (boreProcess && !boreProcess.killed) {
    return { success: false, output: "bore is already running" };
  }

  const boreBin = findBoreBin();
  if (!boreBin) {
    return { success: false, output: "bore.exe not found next to app.js (or set SSH_TOOL_BORE_BIN)" };
  }

  borePublicAddr = null;
  boreLastExit = null;
  boreOutputLines.length = 0;

  const args = ["local", String(BORE_LOCAL_PORT), "--to", BORE_TO];
  appendBoreLine(`> ${boreBin} ${args.join(" ")}`);

  const child = spawn(boreBin, args, { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
  boreProcess = child;

  const addrRe = new RegExp(`\\b${escapeRegExp(BORE_TO)}:(\\d+)\\b`);
  const onData = (chunk) => {
    const text = chunk.toString("utf8");
    for (const line of text.split(/\r?\n/)) appendBoreLine(line);
    const match = text.match(addrRe);
    if (match) borePublicAddr = `${BORE_TO}:${match[1]}`;
  };

  child.stdout.on("data", onData);
  child.stderr.on("data", onData);

  child.on("error", (err) => {
    boreLastExit = { code: null, at: new Date().toISOString(), error: err?.message || String(err) };
    appendBoreLine(`< spawn error: ${err?.message || err}`);
    boreProcess = null;
    borePublicAddr = null;
  });

  child.on("close", (code) => {
    boreLastExit = { code, at: new Date().toISOString() };
    appendBoreLine(`< exited code=${code}`);
    boreProcess = null;
    borePublicAddr = null;
  });

  return { success: true, output: "bore starting" };
}

function stopBore() {
  if (!boreProcess || boreProcess.killed) {
    boreProcess = null;
    borePublicAddr = null;
    return { success: false, output: "bore is not running" };
  }

  try {
    appendBoreLine("> killing bore");
    boreProcess.kill();
  } catch (e) {
    return { success: false, output: `failed to stop bore: ${e?.message || e}` };
  }

  boreProcess = null;
  borePublicAddr = null;
  return { success: true, output: "bore stopped" };
}

// ----- API -----
app.get("/api/logs", (req, res) => {
  res.json({
    logs: logLines.slice(-MAX_LOG_LINES),
    bore: boreOutputLines.slice(-MAX_BORE_LINES),
  });
});

app.get("/api/status", async (req, res) => {
  const [installed, service, firewall, listening, established] = await Promise.all([
    runPS(
      "$svc = Get-Service sshd -ErrorAction SilentlyContinue; if ($svc) { 'Installed' } else { try { $cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*' | Select-Object -First 1; if ($cap) { $cap.State } else { 'NotPresent' } } catch { 'NotPresent' } }"
    ),
    runPS("try { (Get-Service sshd -ErrorAction Stop).Status } catch { 'NotFound' }"),
    runPS(
      "$r = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue; if ($r -and $r.Enabled -eq 'True') { 'Enabled' } else { 'Disabled' }"
    ),
    runPS(
      "try { (Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count } catch { 0 }"
    ),
    runPS(
      "try { (Get-NetTCPConnection -LocalPort 22 -State Established -ErrorAction SilentlyContinue | Measure-Object).Count } catch { 0 }"
    ),
  ]);

  const ip = pickLanIp();
  const username = os.userInfo().username;
  const sshdListening = Number.parseInt(listening.output || "0", 10) > 0;

  res.json({
    success: true,
    platform: "windows",
    openssh_installed: installed.output === "Installed",
    openssh_state: installed.output || "",
    sshd_status: service.output || "",
    sshd_running: service.output === "Running",
    sshd_listening: sshdListening,
    firewall_open: firewall.output === "Enabled",
    ip,
    username,
    hostname: os.hostname(),
    ssh_command: `ssh ${username}@${ip}`,
    active_sessions: Number.parseInt(established.output || "0", 10) || 0,
    auto_shutdown: shutdownAt ? shutdownAt.toISOString() : null,
    auto_shutdown_remain: shutdownAt
      ? Math.max(0, Math.round((shutdownAt.getTime() - Date.now()) / 1000))
      : null,
    bore_running: boreProcess !== null && !boreProcess.killed,
    bore_addr: borePublicAddr,
    bore_ssh: borePublicAddr
      ? `ssh ${username}@${borePublicAddr.split(":")[0]} -p ${borePublicAddr.split(":")[1]}`
      : null,
    bore_last_exit: boreLastExit,
  });
});

app.post("/api/install", async (req, res) => {
  const result = await runPS("Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0");
  res.json(result);
});

app.post("/api/start", async (req, res) => {
  const result = await runPS("Start-Service sshd");
  res.json(result);
});

app.post("/api/stop", async (req, res) => {
  clearTimer();
  const result = await runPS("Stop-Service sshd");
  res.json(result);
});

app.post("/api/autostart", async (req, res) => {
  const result = await runPS("Set-Service -Name sshd -StartupType Automatic");
  res.json(result);
});

app.post("/api/firewall", async (req, res) => {
  const result = await runPS(
    "if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (TCP 22)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 } else { 'Already exists' }"
  );
  res.json(result);
});

app.post("/api/setup-all", async (req, res) => {
  const steps = [];
  const install = await runPS("Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0");
  steps.push({ step: "Install OpenSSH Server", ...install });
  const start = await runPS("Start-Service sshd");
  steps.push({ step: "Start sshd", ...start });
  const auto = await runPS("Set-Service -Name sshd -StartupType Automatic");
  steps.push({ step: "Enable autostart", ...auto });
  const fw = await runPS(
    "if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (TCP 22)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 } else { 'Already exists' }"
  );
  steps.push({ step: "Open firewall", ...fw });
  res.json({ success: true, steps });
});

app.post("/api/timed-start", async (req, res) => {
  const minutesRaw = Number.parseInt(String(req.body?.minutes ?? ""), 10);
  const minutes = Number.isFinite(minutesRaw) ? Math.min(Math.max(minutesRaw, 1), 24 * 60) : 60;

  const start = await runPS("Start-Service sshd");
  if (!start.success) return res.json(start);

  clearTimer();
  shutdownAt = new Date(Date.now() + minutes * 60 * 1000);
  shutdownTimer = setTimeout(async () => {
    await runPS("Stop-Service sshd");
    clearTimer();
    log("info", `Auto-stopped SSH after ${minutes} minutes`);
  }, minutes * 60 * 1000);

  jsonOk(res, { output: `SSH started; will auto-stop in ${minutes} minutes`, shutdown_at: shutdownAt.toISOString() });
});

app.post("/api/cancel-timer", async (req, res) => {
  clearTimer();
  jsonOk(res, { output: "Auto-stop timer cancelled" });
});

app.post("/api/kick-all", async (req, res) => {
  const result = await runPS("Restart-Service sshd");
  res.json({ ...result, output: result.success ? "All SSH sessions disconnected (sshd restarted)" : result.output });
});

app.get("/api/bore-status", (req, res) => {
  res.json({
    success: true,
    running: boreProcess !== null && !boreProcess.killed,
    public_addr: borePublicAddr,
    ssh_command: borePublicAddr
      ? `ssh ${os.userInfo().username}@${borePublicAddr.split(":")[0]} -p ${borePublicAddr.split(":")[1]}`
      : null,
    last_exit: boreLastExit,
    logs: boreOutputLines.slice(-MAX_BORE_LINES),
  });
});

app.post("/api/bore-start", (req, res) => {
  const result = startBore();
  res.json(result);
});

app.post("/api/bore-stop", (req, res) => {
  const result = stopBore();
  res.json(result);
});

app.post("/api/uninstall", async (req, res) => {
  const steps = [];
  clearTimer();

  const stop = await runPS("Stop-Service sshd -ErrorAction SilentlyContinue");
  steps.push({ step: "Stop sshd", ...stop });
  const disable = await runPS("Set-Service -Name sshd -StartupType Disabled -ErrorAction SilentlyContinue");
  steps.push({ step: "Disable autostart", ...disable });
  const fw = await runPS(
    "Remove-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue; 'Done'"
  );
  steps.push({ step: "Remove firewall rule", ...fw });
  const remove = await runPS(
    "Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue; 'Done'"
  );
  steps.push({ step: "Uninstall OpenSSH Server", ...remove });

  res.json({ success: true, steps });
});

app.listen(PORT, HOST, () => {
  log("info", "SSH tool started");
  log("info", `UI: http://${HOST}:${PORT}`);
  log("info", `Token: ${TOKEN} (send as header x-ssh-tool-token)`);
  log("info", `bore: to=${BORE_TO} localPort=${BORE_LOCAL_PORT}`);
});

process.on("SIGINT", () => {
  try {
    stopBore();
  } catch {
    // ignore
  }
  process.exit(0);
});
