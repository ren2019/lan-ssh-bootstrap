package main

import (
	"bytes"
	"crypto/rand"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

//go:embed assets/*
var assets embed.FS

type event struct {
	Attempt string `json:"attempt"`
	Stage   string `json:"stage"`
	Message string `json:"message"`
	User    string `json:"user"`
	SID     string `json:"sid"`
	HostKey string `json:"hostKey"`
	Fresh   bool   `json:"fresh"`
	Port    int    `json:"port"`
}
type target struct {
	event
	IP string
}
type view struct {
	Stage   string `json:"stage"`
	Message string `json:"message"`
	User    string `json:"user,omitempty"`
}
type session struct {
	mu                                         sync.Mutex
	base, authority, token, publicKey, network string
	installer                                  []byte
	state                                      view
	attempt, clientIP, decision                string
	ready                                      chan target
	done                                       chan string
}

func newSession(base, publicKey, network string, installer []byte) *session {
	key := make([]byte, 16)
	if _, err := rand.Read(key); err != nil {
		panic(err)
	}
	return &session{base: base, authority: strings.TrimPrefix(base, "http://"), token: hex.EncodeToString(key), publicKey: publicKey,
		network: network, installer: installer, state: view{Stage: "waiting", Message: "等待运行 Windows 安装命令"}, ready: make(chan target, 2), done: make(chan string, 2)}
}
func (s *session) prefix() string { return "/s/" + s.token }
func (s *session) setDecision(attempt, decision string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if attempt != s.attempt || s.state.Stage == "failed" || s.state.Stage == "cancelled" {
		return false
	}
	s.decision = decision
	return true
}
func (s *session) handler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
	_, subnet, err := net.ParseCIDR(s.network)
	if err != nil || !subnet.Contains(net.ParseIP(peerIP(r))) {
		http.Error(w, "Outside selected local subnet", http.StatusForbidden)
		return
	}
	if r.Host != s.authority {
		http.Error(w, "Invalid host", 400)
		return
	}
	if origin := r.Header.Get("Origin"); origin != "" && origin != s.base {
		http.Error(w, "Invalid origin", 403)
		return
	}
	path := r.URL.Path
	if r.Method != "GET" && !(r.Method == "POST" && path == s.prefix()+"/event") {
		http.Error(w, "Method not allowed", 405)
		return
	}
	switch path {
	case "/":
		page, _ := assets.ReadFile("assets/index.html")
		t := template.Must(template.New("index").Parse(string(page)))
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_ = t.Execute(w, map[string]string{"Prefix": s.prefix(), "Command": "irm " + s.base + s.prefix() + "/setup.ps1 | iex", "Version": packageVersion})
	case "/app.js", "/style.css", "/i18n.json":
		data, _ := assets.ReadFile("assets" + path)
		if path == "/app.js" {
			w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		} else if path == "/i18n.json" {
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
		} else {
			w.Header().Set("Content-Type", "text/css; charset=utf-8")
		}
		_, _ = w.Write(data)
	case "/images/windows-powershell-admin-zh.png", "/images/windows-powershell-admin.jpg", "/images/windows-powershell-search.jpg":
		data, err := assets.ReadFile("assets" + path)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		if strings.HasSuffix(path, ".png") {
			w.Header().Set("Content-Type", "image/png")
		} else {
			w.Header().Set("Content-Type", "image/jpeg")
		}
		_, _ = w.Write(data)
	case s.prefix() + "/setup.ps1":
		core, _ := assets.ReadFile("assets/core.ps1")
		body, _ := assets.ReadFile("assets/windows.ps1")
		language := "zh"
		if r.URL.Query().Get("lang") == "en" {
			language = "en"
		}
		restore, _ := assets.ReadFile("assets/restore.ps1")
		restore = append(append(append([]byte{}, core...), '\n'), restore...)
		config, _ := json.Marshal(map[string]string{"base": s.base + s.prefix(), "publicKey": s.publicKey, "network": s.network, "sha256": packageSHA256, "version": packageVersion, "language": language, "restore": base64.StdEncoding.EncodeToString(append([]byte{0xef, 0xbb, 0xbf}, restore...))})
		// ASCII transport works both through Invoke-RestMethod | IEX and as a
		// downloaded PS5.1 file. A raw UTF-8 BOM can become part of an IEX token.
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Disposition", `attachment; filename="setup.ps1"`)
		payload := fmt.Sprintf("& {\n$BootstrapConfig = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s')) | ConvertFrom-Json\n%s\n%s\n}", base64.StdEncoding.EncodeToString(config), core, body)
		_, _ = fmt.Fprintf(w, "# UTF-8 source is transported as Base64 for Windows PowerShell 5.1 compatibility.\nInvoke-Expression ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s')))\n", base64.StdEncoding.EncodeToString([]byte(payload)))
	case s.prefix() + "/OpenSSH-Win64.msi":
		w.Header().Set("Content-Type", "application/octet-stream")
		http.ServeContent(w, r, "OpenSSH-Win64.msi", time.Time{}, bytes.NewReader(s.installer))
	case s.prefix() + "/status":
		s.mu.Lock()
		state := s.state
		s.mu.Unlock()
		writeJSON(w, state)
	case s.prefix() + "/decision":
		s.mu.Lock()
		defer s.mu.Unlock()
		if r.Header.Get("X-Attempt") != s.attempt || peerIP(r) != s.clientIP {
			http.Error(w, "Other attempt", 409)
			return
		}
		writeJSON(w, map[string]string{"decision": s.decision})
	case s.prefix() + "/event":
		var e event
		r.Body = http.MaxBytesReader(w, r.Body, 8192)
		d := json.NewDecoder(r.Body)
		d.DisallowUnknownFields()
		if err := d.Decode(&e); err != nil {
			http.Error(w, "Invalid event", 400)
			return
		}
		if d.Decode(&struct{}{}) != io.EOF || len(e.Attempt) != 32 || strings.Trim(e.Attempt, "0123456789abcdef") != "" || len(e.Message) > 1000 {
			http.Error(w, "Invalid event", 400)
			return
		}
		if err := s.accept(e, peerIP(r)); err != nil {
			http.Error(w, err.Error(), 409)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	default:
		http.NotFound(w, r)
	}
}
func peerIP(r *http.Request) string { h, _, _ := net.SplitHostPort(r.RemoteAddr); return h }
func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}

func (s *session) accept(e event, ip string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if parsed := net.ParseIP(ip); parsed == nil || parsed.To4() == nil {
		return fmt.Errorf("IPv4 required")
	}
	if e.Stage == "checking" {
		if s.attempt != "" && s.state.Stage != "failed" && s.state.Stage != "cancelled" {
			return fmt.Errorf("已有运行中的安装，请勿重复启动")
		}
	} else if e.Attempt != s.attempt || ip != s.clientIP {
		return fmt.Errorf("Another installation owns this session")
	}
	allowed := map[string][]string{
		"checking": {"waiting", "failed", "cancelled"}, "installing": {"checking"},
		"configuring": {"checking", "installing"}, "ready": {"configuring"},
		"ready-final": {"ready"}, "complete": {"ready-final"},
		"failed":    {"checking", "installing", "configuring", "ready", "ready-final"},
		"cancelled": {"checking"},
	}
	valid := false
	for _, prev := range allowed[e.Stage] {
		if prev == s.state.Stage {
			valid = true
		}
	}
	if !valid {
		return fmt.Errorf("Invalid state transition %s -> %s", s.state.Stage, e.Stage)
	}
	if e.Stage == "ready" || e.Stage == "ready-final" {
		if !validSID(e.SID) || e.User == "" || strings.ContainsAny(e.User, "\r\n\x00") || len(e.User) > 256 || !validHostKey(e.HostKey) || e.Port < 1 || e.Port > 65535 {
			return fmt.Errorf("Invalid target identity")
		}
		if e.Stage == "ready-final" && s.decision != "verify-pass" {
			return fmt.Errorf("Verification not complete")
		}
	}
	if e.Stage == "complete" && s.decision != "finish" {
		return fmt.Errorf("Final verification not complete")
	}
	if (e.Stage == "ready" || e.Stage == "ready-final") && len(s.ready) == cap(s.ready) {
		return fmt.Errorf("Verification queue full")
	}
	if e.Stage == "checking" {
		s.attempt = e.Attempt
		s.clientIP = ip
		s.decision = "wait"
	}
	s.state = view{Stage: e.Stage, Message: e.Message, User: e.User}
	if e.Stage == "ready" || e.Stage == "ready-final" {
		select {
		case s.ready <- target{event: e, IP: ip}:
		default:
			return fmt.Errorf("Verification queue full")
		}
	}
	if e.Stage == "complete" {
		s.done <- "complete"
	}
	return nil
}
func validSID(s string) bool {
	if !strings.HasPrefix(s, "S-1-5-21-") {
		return false
	}
	parts := strings.Split(s, "-")
	if len(parts) != 8 {
		return false
	}
	for _, p := range parts[4:] {
		if p == "" || strings.Trim(p, "0123456789") != "" {
			return false
		}
	}
	return true
}
func validHostKey(s string) bool {
	p := strings.Fields(s)
	if len(p) != 2 || (p[0] != "ssh-ed25519" && p[0] != "ssh-rsa" && p[0] != "ecdsa-sha2-nistp256") {
		return false
	}
	b, err := base64.StdEncoding.DecodeString(p[1])
	return err == nil && len(b) > 24 && len(b) < 4096
}
