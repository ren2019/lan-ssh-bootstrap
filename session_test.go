package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
)

const testKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
const attemptA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const attemptB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

func testSession() *session {
	return newSession("http://192.0.2.10:8765", testKey, "192.0.2.0/24", []byte("installer"))
}
func readyEvent(attempt, stage string) event {
	return event{Attempt: attempt, Stage: stage, User: "test", SID: "S-1-5-21-100-200-300-1001", HostKey: testKey, Port: 22}
}
func sendEvent(t *testing.T, s *session, e event, ip string) {
	t.Helper()
	if err := s.accept(e, ip); err != nil {
		t.Fatal(err)
	}
}
func TestTwoPhaseVerification(t *testing.T) {
	s := testSession()
	ip := "192.0.2.20"
	sendEvent(t, s, event{Attempt: attemptA, Stage: "checking"}, ip)
	sendEvent(t, s, event{Attempt: attemptA, Stage: "configuring"}, ip)
	sendEvent(t, s, readyEvent(attemptA, "ready"), ip)
	if err := s.accept(readyEvent(attemptA, "ready-final"), ip); err == nil {
		t.Fatal("advanced without first verification")
	}
	if s.setDecision(attemptB, "verify-pass") {
		t.Fatal("stale attempt authorized")
	}
	if !s.setDecision(attemptA, "verify-pass") {
		t.Fatal("verification rejected")
	}
	sendEvent(t, s, readyEvent(attemptA, "ready-final"), ip)
	if err := s.accept(event{Attempt: attemptA, Stage: "complete"}, ip); err == nil {
		t.Fatal("completed without second verification")
	}
	s.setDecision(attemptA, "finish")
	sendEvent(t, s, event{Attempt: attemptA, Stage: "complete"}, ip)
	if s.state.Stage != "complete" {
		t.Fatal(s.state)
	}
}
func TestSessionOwnershipAndRetry(t *testing.T) {
	s := testSession()
	ip := "192.0.2.20"
	sendEvent(t, s, event{Attempt: attemptA, Stage: "checking"}, ip)
	if err := s.accept(event{Attempt: attemptB, Stage: "checking"}, "192.0.2.30"); err == nil {
		t.Fatal("concurrent installer accepted")
	}
	if s.attempt != attemptA || s.clientIP != ip {
		t.Fatal("rejected attempt changed session owner")
	}
	if err := s.accept(event{Attempt: attemptA, Stage: "failed"}, "192.0.2.30"); err == nil {
		t.Fatal("another client changed state")
	}
	sendEvent(t, s, event{Attempt: attemptA, Stage: "failed"}, ip)
	sendEvent(t, s, event{Attempt: attemptB, Stage: "checking"}, "192.0.2.30")
	if s.setDecision(attemptA, "finish") {
		t.Fatal("old attempt still owns decisions")
	}
}
func request(s *session, method, path, ip, host, origin string, body []byte) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, s.base+path, bytes.NewReader(body))
	r.RemoteAddr = ip + ":12345"
	r.Host = host
	if origin != "" {
		r.Header.Set("Origin", origin)
	}
	w := httptest.NewRecorder()
	s.handler(w, r)
	return w
}
func TestHTTPBoundaries(t *testing.T) {
	s := testSession()
	for _, c := range []struct {
		path, ip, host, origin string
		status                 int
	}{
		{"/", "192.0.2.20", s.authority, "", 200},
		{"/", "198.51.100.1", s.authority, "", 403},
		{"/", "192.0.2.20", "attacker.invalid:8765", "", 400},
		{"/", "192.0.2.20", s.authority, "https://attacker.invalid", 403},
		{"/../../etc/passwd", "192.0.2.20", s.authority, "", 404},
		{"/assets/windows.ps1", "192.0.2.20", s.authority, "", 404},
		{s.prefix() + "/status", "192.0.2.20", s.authority, "", 200},
	} {
		w := request(s, "GET", c.path, c.ip, c.host, c.origin, nil)
		if w.Code != c.status {
			t.Errorf("%+v: %d", c, w.Code)
		}
	}
	w := request(s, "GET", "/", "192.0.2.20", s.authority, "", nil)
	if !strings.Contains(w.Body.String(), s.prefix()) || !strings.Contains(w.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") {
		t.Fatal("missing page/session boundary")
	}
}
func TestInvalidPayloadAndIdentity(t *testing.T) {
	s := testSession()
	w := request(s, "POST", s.prefix()+"/event", "192.0.2.20", s.authority, "", []byte(`{"attempt":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","stage":"checking","unexpected":"x"}`))
	if w.Code != http.StatusBadRequest {
		t.Fatal(w.Code)
	}
	if s.attempt != "" {
		t.Fatal("invalid payload claimed session")
	}
	sendEvent(t, s, event{Attempt: attemptA, Stage: "checking"}, "192.0.2.20")
	sendEvent(t, s, event{Attempt: attemptA, Stage: "configuring"}, "192.0.2.20")
	e := readyEvent(attemptA, "ready")
	e.Port = 0
	if err := s.accept(e, "192.0.2.20"); err == nil {
		t.Fatal("invalid port accepted")
	}
	e.Port = 22
	e.SID = "S-1-5-18"
	if err := s.accept(e, "192.0.2.20"); err == nil {
		t.Fatal("SYSTEM identity accepted")
	}
}
func TestScriptLanguageAndReceipt(t *testing.T) {
	s := testSession()
	w := request(s, "GET", s.prefix()+"/setup.ps1?lang=en", "192.0.2.20", s.authority, "", nil)
	if w.Code != 200 || strings.HasPrefix(w.Body.String(), "\ufeff") {
		t.Fatal("incomplete generated script")
	}
	for _, r := range w.Body.String() {
		if r > 127 {
			t.Fatal("wire script is not ASCII")
		}
	}
	pattern := regexp.MustCompile(`FromBase64String\('([^']+)'\)`)
	outer := pattern.FindStringSubmatch(w.Body.String())
	if len(outer) != 2 {
		t.Fatal("missing transport")
	}
	decoded, err := base64.StdEncoding.DecodeString(outer[1])
	if err != nil || !strings.Contains(string(decoded), "Wait-Decision 'verify-pass'") {
		t.Fatal("missing workflow payload", err)
	}
	inner := pattern.FindStringSubmatch(string(decoded))
	if len(inner) != 2 {
		t.Fatal("missing session configuration")
	}
	configBytes, err := base64.StdEncoding.DecodeString(inner[1])
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]string
	if err = json.Unmarshal(configBytes, &config); err != nil || config["language"] != "en" {
		t.Fatal("wrong language", err)
	}
	var page map[string]any
	w = request(s, "GET", s.prefix()+"/status", "192.0.2.20", s.authority, "", nil)
	if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil {
		t.Fatal(err)
	}
	if _, exists := page["publicKey"]; exists {
		t.Fatal("public status exposes configuration")
	}
}
