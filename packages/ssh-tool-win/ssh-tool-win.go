//go:build windows
// +build windows

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
)

// Embedded payload files live next to this source file.
//
//go:embed remote-support.ps1
var remoteSupportPS1 []byte

//go:embed bore.exe
var boreExe []byte

//go:embed support.pub
var defaultSupportPub []byte

//go:embed public/remote-support-ui.html
var remoteSupportUIHTML string

type startConfig struct {
	authMode   string
	minutes    int
	relay      string
	localPort  int
	allowLan   bool
	supportPub string
	statePath  string
}

type commonConfig struct {
	supportPub string
	statePath  string
}

func usage() {
	fmt.Fprintln(os.Stderr, "ssh-tool-win.exe — portable Windows remote support helper (SSH + bore)")
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "Usage:")
	fmt.Fprintln(os.Stderr, "  ssh-tool-win.exe ui      [--port 3000] [--host 127.0.0.1]")
	fmt.Fprintln(os.Stderr, "  ssh-tool-win.exe [start] [--minutes 60] [--auth-mode auto|key|password] [--relay bore.pub] [--local-port 22] [--allow-lan] [--support-pub PATH] [--state-path PATH]")
	fmt.Fprintln(os.Stderr, "  ssh-tool-win.exe stop   [--state-path PATH]")
	fmt.Fprintln(os.Stderr, "  ssh-tool-win.exe status [--state-path PATH]")
	fmt.Fprintln(os.Stderr, "  ssh-tool-win.exe recover[--state-path PATH]")
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "Support key selection order:")
	fmt.Fprintln(os.Stderr, "  1) --support-pub PATH")
	fmt.Fprintln(os.Stderr, "  2) support.pub next to the exe")
	fmt.Fprintln(os.Stderr, "  3) embedded support.pub (default)")
}

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		if err := runUI(nil); err != nil {
			fmt.Fprintln(os.Stderr, err.Error())
			os.Exit(1)
		}
		return
	}

	switch args[0] {
	case "-h", "--help", "help":
		usage()
		return
	case "ui", "serve":
		if err := runUI(args[1:]); err != nil {
			fmt.Fprintln(os.Stderr, err.Error())
			os.Exit(1)
		}
		return
	case "start":
		if err := runStart(args[1:]); err != nil {
			fmt.Fprintln(os.Stderr, err.Error())
			os.Exit(1)
		}
		return
	case "stop":
		if err := runSimpleAction("stop", args[1:]); err != nil {
			fmt.Fprintln(os.Stderr, err.Error())
			os.Exit(1)
		}
		return
	case "status":
		if err := runSimpleAction("status", args[1:]); err != nil {
			fmt.Fprintln(os.Stderr, err.Error())
			os.Exit(1)
		}
		return
	case "recover":
		if err := runSimpleAction("recover", args[1:]); err != nil {
			fmt.Fprintln(os.Stderr, err.Error())
			os.Exit(1)
		}
		return
	default:
		// Back-compat: if the user passes flags without an explicit subcommand, treat as start.
		if strings.HasPrefix(args[0], "-") {
			if err := runStart(args); err != nil {
				fmt.Fprintln(os.Stderr, err.Error())
				os.Exit(1)
			}
			return
		}
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n\n", args[0])
		usage()
		os.Exit(2)
	}
}

type uiConfig struct {
	host       string
	port       int
	supportPub string
	statePath  string
	noOpen     bool
}

func runUI(args []string) error {
	fs := flag.NewFlagSet("ui", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	cfg := uiConfig{
		host: "127.0.0.1",
		port: 3000,
	}

	fs.StringVar(&cfg.host, "host", cfg.host, "listen host (default: 127.0.0.1)")
	fs.IntVar(&cfg.port, "port", cfg.port, "listen port (default: 3000; use 0 for random)")
	fs.StringVar(&cfg.supportPub, "support-pub", "", "path to support public key file")
	fs.StringVar(&cfg.statePath, "state-path", "", "override session state file path")
	fs.BoolVar(&cfg.noOpen, "no-open", false, "do not auto-open browser")

	if err := fs.Parse(args); err != nil {
		return err
	}

	if !isAdmin() {
		fmt.Fprintln(os.Stderr, "[*] Requesting administrator privileges...")
		if err := relaunchAsAdmin(append([]string{"ui"}, args...)); err != nil {
			return err
		}
		return nil
	}

	payloadDir, err := ensurePayloadDir(cfg.supportPub)
	if err != nil {
		return err
	}

	statePath := cfg.statePath
	if strings.TrimSpace(statePath) == "" {
		statePath = getEnvDefault("SSH_TOOL_STATE_PATH", `C:\ProgramData\ssh-tool\active-session.json`)
	}

	token, err := newTokenHex(24)
	if err != nil {
		return err
	}

	s := &uiServer{
		token:      token,
		payloadDir: payloadDir,
		statePath:  statePath,
		supportPub: cfg.supportPub,
	}
	s.logf("UI token: %s", token)

	addr := net.JoinHostPort(cfg.host, strconv.Itoa(cfg.port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		if cfg.port != 0 {
			// Fallback to a random port if the default is already occupied.
			addr = net.JoinHostPort(cfg.host, "0")
			ln, err = net.Listen("tcp", addr)
		}
		if err != nil {
			return err
		}
	}
	defer ln.Close()

	listenPort := 0
	if tcp, ok := ln.Addr().(*net.TCPAddr); ok {
		listenPort = tcp.Port
	}

	openHost := cfg.host
	if openHost == "" || openHost == "0.0.0.0" || openHost == "::" {
		openHost = "127.0.0.1"
	}
	url := fmt.Sprintf("http://%s:%d/", openHost, listenPort)
	s.logf("UI: %s", url)
	fmt.Printf("[*] UI: %s\n", url)
	fmt.Println("[*] Keep this window open while using the UI. Press Ctrl+C to exit.")

	if !cfg.noOpen {
		_ = openBrowser(url)
	}

	server := &http.Server{
		Handler: s.mux(),
	}

	err = server.Serve(ln)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

type uiServer struct {
	token      string
	payloadDir string
	statePath  string
	supportPub string

	mu   sync.Mutex
	logs []string
}

func (s *uiServer) mux() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/api/status", s.requireToken(s.handleStatus))
	mux.HandleFunc("/api/start", s.requireToken(s.handleStart))
	mux.HandleFunc("/api/stop", s.requireToken(s.handleStop))
	mux.HandleFunc("/api/recover", s.requireToken(s.handleRecover))
	mux.HandleFunc("/api/logs", s.requireToken(s.handleLogs))
	return mux
}

func (s *uiServer) handleIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("content-type", "text/html; charset=utf-8")
	html := strings.ReplaceAll(remoteSupportUIHTML, "__SSH_TOOL_TOKEN__", s.token)
	_, _ = io.WriteString(w, html)
}

func (s *uiServer) requireToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("x-ssh-tool-token") != s.token {
			writeJSON(w, http.StatusUnauthorized, map[string]any{`success`: false, `output`: `Unauthorized`})
			return
		}
		next(w, r)
	}
}

type sessionState struct {
	SessionID  string  `json:"session_id"`
	CreatedAt  string  `json:"created_at"`
	ExpiresAt  string  `json:"expires_at"`
	AuthMode   string  `json:"auth_mode"`
	AllowLan   bool    `json:"allow_lan"`
	SSHUser    string  `json:"ssh_user"`
	SSHPass    *string `json:"ssh_password"`
	SSHCommand *string `json:"ssh_command"`
	Relay      string  `json:"relay"`
	RelayHost  string  `json:"relay_host"`
	PublicPort *string `json:"public_port"`
	BoreOut    *string `json:"bore_out"`
	BoreErr    *string `json:"bore_err"`
}

func (s *uiServer) handleStatus(w http.ResponseWriter, r *http.Request) {
	st, err := readStateFile(s.statePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeJSON(w, http.StatusOK, map[string]any{
				"success": true,
				"active":  false,
			})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"success": false, "output": err.Error()})
		return
	}

	resp := map[string]any{
		"success":      true,
		"active":       true,
		"session_id":   st.SessionID,
		"created_at":   st.CreatedAt,
		"expires_at":   st.ExpiresAt,
		"auth_mode":    st.AuthMode,
		"allow_lan":    st.AllowLan,
		"ssh_user":     st.SSHUser,
		"ssh_password": derefOrEmpty(st.SSHPass),
		"ssh_command":  derefOrEmpty(st.SSHCommand),
		"relay":        st.Relay,
		"relay_host":   st.RelayHost,
		"public_port":  derefOrEmpty(st.PublicPort),
	}

	if st.ExpiresAt != "" {
		if t, err := time.Parse(time.RFC3339Nano, st.ExpiresAt); err == nil {
			remain := int64(t.Sub(time.Now().UTC()).Seconds())
			if remain < 0 {
				remain = 0
			}
			resp["expires_remain_s"] = remain
		}
	}

	writeJSON(w, http.StatusOK, resp)
}

type startRequest struct {
	Minutes   int    `json:"minutes"`
	AuthMode  string `json:"auth_mode"`
	Relay     string `json:"relay"`
	LocalPort int    `json:"local_port"`
	AllowLan  bool   `json:"allow_lan"`
}

func (s *uiServer) handleStart(w http.ResponseWriter, r *http.Request) {
	var req startRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 64*1024)).Decode(&req); err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"success": false, "output": "Invalid JSON"})
		return
	}

	if err := s.refreshSupportPub(); err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"success": false, "output": err.Error()})
		return
	}

	if req.Minutes <= 0 {
		req.Minutes = 60
	}
	if req.Minutes < 1 {
		req.Minutes = 1
	}
	if req.Minutes > 1440 {
		req.Minutes = 1440
	}

	if req.LocalPort <= 0 {
		req.LocalPort = 22
	}
	if req.LocalPort < 1 {
		req.LocalPort = 1
	}
	if req.LocalPort > 65535 {
		req.LocalPort = 65535
	}

	req.AuthMode = strings.TrimSpace(req.AuthMode)
	if req.AuthMode == "" {
		req.AuthMode = "auto"
	}
	if req.AuthMode != "auto" && req.AuthMode != "key" && req.AuthMode != "password" {
		writeJSON(w, http.StatusOK, map[string]any{"success": false, "output": "Invalid auth_mode"})
		return
	}

	req.Relay = strings.TrimSpace(req.Relay)
	if req.Relay == "" {
		req.Relay = "bore.pub"
	}

	out, err := s.runRemoteSupport("start", func(scriptPath string) []string {
		args := []string{
			"-NoProfile",
			"-NonInteractive",
			"-ExecutionPolicy", "Bypass",
			"-File", scriptPath,
			"-Action", "start",
			"-AuthMode", req.AuthMode,
			"-Minutes", fmt.Sprintf("%d", req.Minutes),
			"-Relay", req.Relay,
			"-LocalPort", fmt.Sprintf("%d", req.LocalPort),
			"-SupportKeyPath", filepath.Join(filepath.Dir(scriptPath), "support.pub"),
			"-TargetUser", getEnvDefault("USERNAME", getEnvDefault("USER", "user")),
			"-TargetUserHome", getEnvDefault("USERPROFILE", mustUserHomeDir()),
			"-StatePath", s.statePath,
		}
		if req.AllowLan {
			args = append(args, "-AllowLan")
		}
		return args
	}, 120*time.Second)

	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"success": false, "output": trimOutput(out, err)})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"success": true, "output": strings.TrimSpace(out)})
}

func (s *uiServer) refreshSupportPub() error {
	b, err := selectSupportPubBytes(s.supportPub)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(s.payloadDir, "support.pub"), b, 0o644)
}

func (s *uiServer) handleStop(w http.ResponseWriter, r *http.Request) {
	out, err := s.runRemoteSupport("stop", func(scriptPath string) []string {
		return []string{
			"-NoProfile",
			"-NonInteractive",
			"-ExecutionPolicy", "Bypass",
			"-File", scriptPath,
			"-Action", "stop",
			"-SupportKeyPath", filepath.Join(filepath.Dir(scriptPath), "support.pub"),
			"-TargetUser", getEnvDefault("USERNAME", getEnvDefault("USER", "user")),
			"-TargetUserHome", getEnvDefault("USERPROFILE", mustUserHomeDir()),
			"-StatePath", s.statePath,
		}
	}, 120*time.Second)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"success": false, "output": trimOutput(out, err)})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "output": strings.TrimSpace(out)})
}

func (s *uiServer) handleRecover(w http.ResponseWriter, r *http.Request) {
	out, err := s.runRemoteSupport("recover", func(scriptPath string) []string {
		return []string{
			"-NoProfile",
			"-NonInteractive",
			"-ExecutionPolicy", "Bypass",
			"-File", scriptPath,
			"-Action", "recover",
			"-SupportKeyPath", filepath.Join(filepath.Dir(scriptPath), "support.pub"),
			"-TargetUser", getEnvDefault("USERNAME", getEnvDefault("USER", "user")),
			"-TargetUserHome", getEnvDefault("USERPROFILE", mustUserHomeDir()),
			"-StatePath", s.statePath,
		}
	}, 120*time.Second)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"success": false, "output": trimOutput(out, err)})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "output": strings.TrimSpace(out)})
}

func (s *uiServer) handleLogs(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	logs := append([]string(nil), s.logs...)
	s.mu.Unlock()

	var bore []string
	if st, err := readStateFile(s.statePath); err == nil {
		bore = append(bore, tailPathLines(derefOrEmpty(st.BoreOut), 120)...)
		bore = append(bore, tailPathLines(derefOrEmpty(st.BoreErr), 120)...)
		if len(bore) > 200 {
			bore = bore[len(bore)-200:]
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"success": true,
		"logs":    logs,
		"bore":    bore,
	})
}

func (s *uiServer) logf(format string, args ...any) {
	line := fmt.Sprintf("%s %s", time.Now().Format(time.RFC3339), fmt.Sprintf(format, args...))
	s.mu.Lock()
	s.logs = append(s.logs, line)
	if len(s.logs) > 500 {
		s.logs = s.logs[len(s.logs)-500:]
	}
	s.mu.Unlock()
}

func (s *uiServer) runRemoteSupport(name string, buildArgs func(scriptPath string) []string, timeout time.Duration) (string, error) {
	scriptPath := filepath.Join(s.payloadDir, "remote-support.ps1")
	args := buildArgs(scriptPath)
	if len(args) == 0 {
		return "", errors.New("invalid powershell args")
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "powershell.exe", args...)
	cmd.Dir = s.payloadDir
	cmd.Env = append(os.Environ(), "SSH_TOOL_NO_OPEN_HTML=1")

	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()

	out := strings.TrimSpace(buf.String())
	if out != "" {
		for _, line := range splitLines(out) {
			s.logf("%s: %s", name, line)
		}
	} else {
		s.logf("%s: (no output)", name)
	}

	if ctx.Err() == context.DeadlineExceeded {
		return out, fmt.Errorf("%s timed out", name)
	}
	return out, err
}

func runStart(args []string) error {
	fs := flag.NewFlagSet("start", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	cfg := startConfig{
		authMode:  "auto",
		minutes:   60,
		relay:     "bore.pub",
		localPort: 22,
	}
	fs.StringVar(&cfg.authMode, "auth-mode", cfg.authMode, "auto|key|password")
	fs.IntVar(&cfg.minutes, "minutes", cfg.minutes, "session duration (1-1440)")
	fs.StringVar(&cfg.relay, "relay", cfg.relay, "bore relay host (default: bore.pub)")
	fs.IntVar(&cfg.localPort, "local-port", cfg.localPort, "local SSH port (default: 22)")
	fs.BoolVar(&cfg.allowLan, "allow-lan", false, "allow LAN access (otherwise bind to 127.0.0.1 only)")
	fs.StringVar(&cfg.supportPub, "support-pub", "", "path to support public key file")
	fs.StringVar(&cfg.statePath, "state-path", "", "override session state file path")

	if err := fs.Parse(args); err != nil {
		return err
	}

	return runActionWithPayload("start", commonConfig{supportPub: cfg.supportPub, statePath: cfg.statePath}, func(scriptPath string) *exec.Cmd {
		psArgs := []string{
			"-NoProfile",
			"-NonInteractive",
			"-ExecutionPolicy", "Bypass",
			"-File", scriptPath,
			"-Action", "start",
			"-AuthMode", cfg.authMode,
			"-Minutes", fmt.Sprintf("%d", cfg.minutes),
			"-Relay", cfg.relay,
			"-LocalPort", fmt.Sprintf("%d", cfg.localPort),
			"-SupportKeyPath", filepath.Join(filepath.Dir(scriptPath), "support.pub"),
			"-TargetUser", getEnvDefault("USERNAME", getEnvDefault("USER", "user")),
			"-TargetUserHome", getEnvDefault("USERPROFILE", mustUserHomeDir()),
		}
		if cfg.allowLan {
			psArgs = append(psArgs, "-AllowLan")
		}
		if cfg.statePath != "" {
			psArgs = append(psArgs, "-StatePath", cfg.statePath)
		}
		return exec.Command("powershell.exe", psArgs...)
	})
}

func runSimpleAction(action string, args []string) error {
	fs := flag.NewFlagSet(action, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	cfg := commonConfig{}
	fs.StringVar(&cfg.supportPub, "support-pub", "", "path to support public key file (ignored for non-start actions)")
	fs.StringVar(&cfg.statePath, "state-path", "", "override session state file path")
	if err := fs.Parse(args); err != nil {
		return err
	}

	return runActionWithPayload(action, cfg, func(scriptPath string) *exec.Cmd {
		psArgs := []string{
			"-NoProfile",
			"-NonInteractive",
			"-ExecutionPolicy", "Bypass",
			"-File", scriptPath,
			"-Action", action,
			"-SupportKeyPath", filepath.Join(filepath.Dir(scriptPath), "support.pub"),
			"-TargetUser", getEnvDefault("USERNAME", getEnvDefault("USER", "user")),
			"-TargetUserHome", getEnvDefault("USERPROFILE", mustUserHomeDir()),
		}
		if cfg.statePath != "" {
			psArgs = append(psArgs, "-StatePath", cfg.statePath)
		}
		return exec.Command("powershell.exe", psArgs...)
	})
}

func runActionWithPayload(action string, cfg commonConfig, buildCmd func(scriptPath string) *exec.Cmd) error {
	payloadDir, err := ensurePayloadDir(cfg.supportPub)
	if err != nil {
		return err
	}

	scriptPath := filepath.Join(payloadDir, "remote-support.ps1")
	cmd := buildCmd(scriptPath)
	cmd.Dir = payloadDir
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		return err
	}
	return nil
}

func ensurePayloadDir(supportPubPath string) (string, error) {
	h := sha256.New()
	_, _ = h.Write(remoteSupportPS1)
	_, _ = h.Write(boreExe)
	payloadID := hex.EncodeToString(h.Sum(nil))[:12]

	base := payloadBaseDir()
	payloadDir := filepath.Join(base, "payload-"+payloadID)
	if err := os.MkdirAll(payloadDir, 0o755); err != nil {
		return "", err
	}

	if err := writeIfMissing(filepath.Join(payloadDir, "remote-support.ps1"), remoteSupportPS1); err != nil {
		return "", err
	}
	if err := writeIfMissing(filepath.Join(payloadDir, "bore.exe"), boreExe); err != nil {
		return "", err
	}

	supportPubBytes, err := selectSupportPubBytes(supportPubPath)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(payloadDir, "support.pub"), supportPubBytes, 0o644); err != nil {
		return "", err
	}
	return payloadDir, nil
}

func payloadBaseDir() string {
	if v := strings.TrimSpace(os.Getenv("SSH_TOOL_PAYLOAD_DIR")); v != "" {
		return v
	}
	if v := strings.TrimSpace(os.Getenv("LOCALAPPDATA")); v != "" {
		return filepath.Join(v, "ssh-tool-win")
	}
	return filepath.Join(os.TempDir(), "ssh-tool-win")
}

func selectSupportPubBytes(cliPath string) ([]byte, error) {
	if cliPath != "" {
		return os.ReadFile(cliPath)
	}

	exePath, err := os.Executable()
	if err == nil && exePath != "" {
		exeDir := filepath.Dir(exePath)
		p := filepath.Join(exeDir, "support.pub")
		if b, err := os.ReadFile(p); err == nil {
			return b, nil
		}
	}

	return defaultSupportPub, nil
}

func writeIfMissing(path string, data []byte) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	return os.WriteFile(path, data, 0o644)
}

func getEnvDefault(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func mustUserHomeDir() string {
	home, err := os.UserHomeDir()
	if err == nil && strings.TrimSpace(home) != "" {
		return home
	}
	return ""
}

func newTokenHex(bytesLen int) (string, error) {
	b := make([]byte, bytesLen)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func isAdmin() bool {
	const script = "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'true' } else { 'false' }"
	out, err := runPSCommand(script, 10*time.Second)
	if err != nil {
		return false
	}
	return strings.Contains(strings.ToLower(out), "true")
}

func relaunchAsAdmin(args []string) error {
	exePath, err := os.Executable()
	if err != nil {
		return err
	}

	quotedExe := psSingleQuote(exePath)
	quotedArgs := make([]string, 0, len(args))
	for _, a := range args {
		quotedArgs = append(quotedArgs, psSingleQuote(a))
	}
	ps := fmt.Sprintf("$exe = %s; $args = @(%s); Start-Process -FilePath $exe -Verb RunAs -ArgumentList $args",
		quotedExe,
		strings.Join(quotedArgs, ", "),
	)

	_, err = runPSCommand(ps, 30*time.Second)
	return err
}

func openBrowser(url string) error {
	cmd := exec.Command("cmd.exe", "/c", "start", "", url)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Start()
}

func runPSCommand(script string, timeout time.Duration) (string, error) {
	encoded := encodePSScript(script)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	out := strings.TrimSpace(buf.String())
	if ctx.Err() == context.DeadlineExceeded {
		return out, errors.New("powershell timed out")
	}
	return out, err
}

func encodePSScript(script string) string {
	u16 := utf16.Encode([]rune(script))
	b := make([]byte, 0, len(u16)*2)
	for _, v := range u16 {
		b = append(b, byte(v), byte(v>>8))
	}
	return base64.StdEncoding.EncodeToString(b)
}

func psSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("content-type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(true)
	_ = enc.Encode(payload)
}

func readStateFile(path string) (*sessionState, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	b = bytes.TrimPrefix(b, []byte{0xEF, 0xBB, 0xBF}) // UTF-8 BOM (PowerShell 5.1 may write it)
	var st sessionState
	if err := json.Unmarshal(b, &st); err != nil {
		return nil, err
	}
	return &st, nil
}

func derefOrEmpty[T ~string](v *T) string {
	if v == nil {
		return ""
	}
	return string(*v)
}

func splitLines(s string) []string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	parts := strings.Split(s, "\n")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}

func trimOutput(output string, err error) string {
	output = strings.TrimSpace(output)
	if output != "" {
		return output
	}
	if err == nil {
		return ""
	}
	return err.Error()
}

func tailPathLines(path string, maxLines int) []string {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	lines := splitLines(string(b))
	if len(lines) <= maxLines {
		return lines
	}
	return lines[len(lines)-maxLines:]
}
