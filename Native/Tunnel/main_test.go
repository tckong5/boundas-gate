package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const testID = "abcdef123456"

func readyAgent() *agent {
	return &agent{id: testID, statusSource: func(context.Context) (*statusData, error) {
		return &statusData{state: "Running", hostname: "boundas.example.ts.net", userspace: true, funnelAllowed: true, httpsEnabled: true}, nil
	}, listen: func() (net.Listener, error) { return net.Listen("tcp", "127.0.0.1:0") }}
}
func TestPublicRoutes(t *testing.T) {
	for _, r := range []string{"/c2c/" + testID + "/mcp", "/c2c/" + testID + "/oauth/token", "/.well-known/oauth-protected-resource/c2c/" + testID + "/mcp"} {
		if _, ok := publicPath(testID, r); !ok {
			t.Fatalf("expected route %s", r)
		}
	}
	for _, r := range []string{"/control/info", "/admin/info", "/mcp", "/c2c/" + testID + "/../control/info", "/c2c/other/mcp", "/c2c/" + testID + "/mcp/extra"} {
		if _, ok := publicPath(testID, r); ok {
			t.Fatalf("unsafe route %s", r)
		}
	}
}
func TestProxyPreservesOAuthAndBlocksAdmin(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/oauth/token" || r.URL.RawQuery != "resource=abc" || r.Header.Get("Authorization") != "Bearer test" {
			t.Error("OAuth request changed")
		}
		if r.Header.Get("Proxy-Authorization") != "" {
			t.Error("proxy credentials forwarded")
		}
		w.Header().Set("Location", "https://boundas.example.ts.net/c2c/"+testID+"/mcp")
		w.WriteHeader(302)
		fmt.Fprint(w, "preserved")
	}))
	defer backend.Close()
	var port int
	_, _ = fmt.Sscanf(strings.TrimPrefix(backend.URL, "http://127.0.0.1:"), "%d", &port)
	handler := publicHandler(testID, port)
	r := httptest.NewRequest("POST", "https://boundas.example.ts.net/c2c/"+testID+"/oauth/token?resource=abc", strings.NewReader("test body"))
	r.Header.Set("Authorization", "Bearer test")
	r.Header.Set("Proxy-Authorization", "private")
	out := httptest.NewRecorder()
	handler.ServeHTTP(out, r)
	if out.Code != 302 || out.Body.String() != "preserved" {
		t.Fatal("proxy changed response")
	}
	for _, p := range []string{"/c2c/" + testID + "/control/info", "/c2c/" + testID + "/%6dcp", "/c2c/" + testID + "/../mcp"} {
		out = httptest.NewRecorder()
		handler.ServeHTTP(out, httptest.NewRequest("GET", "http://localhost"+p, nil))
		if out.Code != 404 {
			t.Fatalf("unsafe path accepted: %s", p)
		}
	}
}
func TestExpectedURLMismatchDoesNotStopExistingListener(t *testing.T) {
	a := readyAgent()
	a.running = true
	a.publicURL = "https://boundas.example.ts.net/c2c/" + testID
	r := httptest.NewRequest("POST", "http://localhost/start", strings.NewReader(`{"port":1234,"expectedURL":"https://old.example.ts.net/c2c/abcdef123456"}`))
	out := httptest.NewRecorder()
	a.control(out, r)
	if out.Code != 409 || !a.running {
		t.Fatal("migration overwrote existing connection")
	}
}
func TestStartStopAndRestartKeepNodeIdentity(t *testing.T) {
	a := readyAgent()
	call := func(route, body string) *httptest.ResponseRecorder {
		out := httptest.NewRecorder()
		a.control(out, httptest.NewRequest("POST", "http://localhost"+route, strings.NewReader(body)))
		return out
	}
	first := call("/start", `{"port":1234}`)
	if first.Code != 200 || !a.running {
		t.Fatal(first.Body.String())
	}
	url := a.publicURL
	if call("/stop", `{}`).Code != 200 || a.running {
		t.Fatal("stop failed")
	}
	if call("/start", `{"port":5678}`).Code != 200 || a.publicURL != url {
		t.Fatal("restart changed URL")
	}
	a.stop()
}
func TestTargetCannotBeAnArbitraryURL(t *testing.T) {
	a := readyAgent()
	defer a.stop()
	for _, body := range []string{`{"port":0}`, `{"port":65536}`, `{"port":1234,"url":"http://example.com"}`, `{"port":1234,"path":"/control/info"}`} {
		out := httptest.NewRecorder()
		a.control(out, httptest.NewRequest("POST", "http://localhost/start", strings.NewReader(body)))
		if out.Code != 400 {
			t.Fatal("invalid target accepted")
		}
	}
}
func TestLoginURLValidationAndUserspace(t *testing.T) {
	a := readyAgent()
	a.statusSource = func(context.Context) (*statusData, error) {
		return &statusData{state: "NeedsLogin", loginURL: "https://example.com/login", userspace: true}, nil
	}
	reply := a.status(context.Background())
	if reply.State != "login" || reply.LoginURL != "" {
		t.Fatal("invalid login link accepted")
	}
	a.statusSource = func(context.Context) (*statusData, error) {
		return &statusData{state: "NeedsLogin", loginURL: "https://login.tailscale.com/a/test", userspace: true}, nil
	}
	if a.status(context.Background()).LoginURL == "" {
		t.Fatal("valid login link missing")
	}
	a.statusSource = func(context.Context) (*statusData, error) {
		return &statusData{state: "Running", userspace: false}, nil
	}
	if a.status(context.Background()).State != "blocked" {
		t.Fatal("kernel networking accepted")
	}
}
func TestStatusUsesOnlySafeFields(t *testing.T) {
	a := readyAgent()
	out := httptest.NewRecorder()
	a.control(out, httptest.NewRequest("GET", "http://localhost/status", nil))
	var reply map[string]any
	if json.Unmarshal(out.Body.Bytes(), &reply) != nil || reply["gatewayID"] != testID || reply["userspace"] != true {
		t.Fatal("invalid status")
	}
}
