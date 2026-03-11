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
    if (lower.includes("docker") || lower.includes("vmware") || lower.includes("virtualbox") || lower.includes("loopback")) {
      continue;
    }
    for (const iface of interfaces[name] || []) {
      if (iface.family === "IPv4" && !iface.internal) candidates.push({ name, address: iface.address });
    }
  }
  const preferred = candidates.find((c) => c.address.startsWith("192.168.") || c.address.startsWith("10."));
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

function isRoot() {
  return typeof process.getuid === "function" && process.getuid() === 0;
}

app.use(express.json({ limit: "64kb" }));
app.use("/api", requireToken);
app.use(express.static(path.join(__dirname, "public")));

function runCmd(cmd, args, { timeoutMs = 20_000 } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"] });
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
      resolve({ success: code === 0, output: (stdout || stderr).trim(), code });
    });
  });
}

async function getRemoteLogin() {
  const result = await runCmd("/usr/sbin/systemsetup", ["-getremotelogin"], { timeoutMs: 10_000 });
  if (!result.success) return { enabled: null, raw: result.output };
  const m = result.output.match(/Remote Login:\s*(On|Off)/i);
  if (!m) return { enabled: null, raw: result.output };
  return { enabled: m[1].toLowerCase() === "on", raw: result.output };
}

async function isPortListening22() {
  const lsof = await runCmd("lsof", ["-nP", "-iTCP:22", "-sTCP:LISTEN"], { timeoutMs: 10_000 });
  if (lsof.success && lsof.output) return true;

  // fallback: netstat (macOS has netstat by default)
  const netstat = await runCmd("netstat", ["-anp", "tcp"], { timeoutMs: 10_000 });
  if (!netstat.success) return false;
  return /(\.22\s+|\:22\s+).*LISTEN/i.test(netstat.output);
}

async function activeSshSessions() {
  const lsof = await runCmd("lsof", ["-nP", "-iTCP:22", "-sTCP:ESTABLISHED"], { timeoutMs: 10_000 });
  if (!lsof.success || !lsof.output) return 0;
  // subtract header line
  const lines = lsof.output.split(/\r?\n/).filter(Boolean);
  return Math.max(0, lines.length - 1);
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

  const local = path.join(__dirname, "bore");
  if (fs.existsSync(local)) return local;

  return "bore"; // rely on PATH (brew install bore-cli)
}

function startBore() {
  if (boreProcess && !boreProcess.killed) {
    return { success: false, output: "bore is already running" };
  }

  borePublicAddr = null;
  boreLastExit = null;
  boreOutputLines.length = 0;

  const boreBin = findBoreBin();
  const args = ["local", String(BORE_LOCAL_PORT), "--to", BORE_TO];
  appendBoreLine(`> ${boreBin} ${args.join(" ")}`);

  const child = spawn(boreBin, args, { stdio: ["ignore", "pipe", "pipe"] });
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
  const ip = pickLanIp();
  const username = os.userInfo().username;

  const [remoteLogin, listening, sessions] = await Promise.all([
    getRemoteLogin(),
    isPortListening22(),
    activeSshSessions(),
  ]);

  res.json({
    success: true,
    platform: "macos",
    openssh_installed: true,
    openssh_state: "built-in",
    sshd_running: listening,
    sshd_status: listening ? "Listening" : "Not listening",
    sshd_listening: listening,
    remote_login_enabled: remoteLogin.enabled,
    remote_login_raw: remoteLogin.raw,
    firewall_open: null,
    ip,
    username,
    hostname: os.hostname(),
    ssh_command: `ssh ${username}@${ip}`,
    active_sessions: sessions,
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
    need_root: !isRoot(),
  });
});

app.post("/api/install", async (req, res) => {
  jsonErr(res, "Not applicable on macOS (OpenSSH is built-in)", 400);
});

async function setRemoteLogin(enabled) {
  if (!isRoot()) return { success: false, output: "This action requires root. Start server with: sudo -E node app.js" };
  const state = enabled ? "on" : "off";
  return runCmd("/usr/sbin/systemsetup", ["-setremotelogin", state], { timeoutMs: 30_000 });
}

app.post("/api/start", async (req, res) => {
  const result = await setRemoteLogin(true);
  res.json(result);
});

app.post("/api/stop", async (req, res) => {
  clearTimer();
  const result = await setRemoteLogin(false);
  res.json(result);
});

app.post("/api/autostart", async (req, res) => {
  // Remote Login is persistent; treat as "enable"
  const result = await setRemoteLogin(true);
  res.json({ ...result, output: result.success ? "Remote Login enabled (persistent)" : result.output });
});

app.post("/api/firewall", async (req, res) => {
  jsonErr(res, "Not implemented on macOS (manage firewall separately if needed)", 400);
});

app.post("/api/setup-all", async (req, res) => {
  const steps = [];
  const enable = await setRemoteLogin(true);
  steps.push({ step: "Enable Remote Login", ...enable });
  res.json({ success: true, steps });
});

app.post("/api/timed-start", async (req, res) => {
  const minutesRaw = Number.parseInt(String(req.body?.minutes ?? ""), 10);
  const minutes = Number.isFinite(minutesRaw) ? Math.min(Math.max(minutesRaw, 1), 24 * 60) : 60;

  const start = await setRemoteLogin(true);
  if (!start.success) return res.json(start);

  clearTimer();
  shutdownAt = new Date(Date.now() + minutes * 60 * 1000);
  shutdownTimer = setTimeout(async () => {
    await setRemoteLogin(false);
    clearTimer();
    log("info", `Auto-disabled Remote Login after ${minutes} minutes`);
  }, minutes * 60 * 1000);

  jsonOk(res, { output: `Remote Login enabled; will auto-disable in ${minutes} minutes`, shutdown_at: shutdownAt.toISOString() });
});

app.post("/api/cancel-timer", async (req, res) => {
  clearTimer();
  jsonOk(res, { output: "Auto-stop timer cancelled" });
});

app.post("/api/kick-all", async (req, res) => {
  if (!isRoot()) return jsonErr(res, "This action requires root. Start server with: sudo -E node app.js", 400);
  const result = await runCmd("/bin/launchctl", ["kickstart", "-k", "system/com.openssh.sshd"], { timeoutMs: 15_000 });
  res.json({ ...result, output: result.success ? "sshd restarted" : result.output });
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
  jsonErr(res, "Not implemented on macOS (disable Remote Login instead)", 400);
});

app.listen(PORT, HOST, () => {
  log("info", "SSH tool started");
  log("info", `UI: http://${HOST}:${PORT}`);
  log("info", `Token: ${TOKEN} (send as header x-ssh-tool-token)`);
  log("info", `Run as root for start/stop: sudo -E node app.js`);
  log("info", `bore: to=${BORE_TO} localPort=${BORE_LOCAL_PORT} (install with: brew install bore-cli)`);
});

process.on("SIGINT", () => {
  try {
    stopBore();
  } catch {
    // ignore
  }
  process.exit(0);
});
