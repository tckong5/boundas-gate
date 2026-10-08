package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"tailscale.com/ipn"
)

const testID = "abcdef123456"

type testLoginNotifications struct {
	events []ipn.Notify
	err    error
	closed bool
}

func (w *testLoginNotifications) Next() (ipn.Notify, error) {
	if len(w.events) == 0 {
		return ipn.Notify{}, w.err
	}
	n := w.events[0]
	w.events = w.events[1:]
	return n, nil
}
func (w *testLoginNotifications) Close() error { w.closed = true; return nil }

func TestInteractiveLoginSubscribesBeforeRequestAndReturnsAsyncURL(t *testing.T) {
	a := readyAgent()
	a.statusSource = func(context.Context) (*statusData, error) {
		return &statusData{state: "NeedsLogin", userspace: true}, nil
	}
	loginURL := "https://login.tailscale.com/a/test"
	needsLogin := ipn.NeedsLogin
	w := &testLoginNotifications{events: []ipn.Notify{{State: &needsLogin}, {BrowseToURL: &loginURL}}}
	subscribed := false
	err := a.receiveLogin(context.Background(), func(context.Context) (loginNotifications, error) {
		subscribed = true
		return w, nil
	}, func(context.Context) error {
		if !subscribed {
			t.Fatal("login requested before subscribing")
		}
		return nil
	})
	if err != nil || !w.closed || a.status(context.Background()).LoginURL != loginURL {
		t.Fatal("asynchronous login URL was lost")
	}
	a.statusSource = readyAgent().statusSource
	if a.status(context.Background()).LoginURL != "" || a.loginURL != "" {
		t.Fatal("login URL survived successful sign-in")
	}
}

func TestInteractiveLoginFailuresNeverSupplyAnUnsafeOrMissingURL(t *testing.T) {
	for _, scenario := range []string{"timeout", "untrusted", "credentials", "request-failed"} {
		t.Run(scenario, func(t *testing.T) {
			a := readyAgent()
			w := &testLoginNotifications{err: context.DeadlineExceeded}
			if scenario == "untrusted" || scenario == "credentials" {
				u := "https://evil.test/login"
				if scenario == "credentials" {
					u = "https://user:secret@login.tailscale.com/login"
				}
				w.events = []ipn.Notify{{BrowseToURL: &u}}
			}
			err := a.receiveLogin(context.Background(), func(context.Context) (loginNotifications, error) { return w, nil },
				func(context.Context) error {
					if scenario == "request-failed" {
						return errors.New("request failed")
					}
					return nil
				})
			if err == nil || !w.closed || a.loginURL != "" {
				t.Fatal("login failure was silently accepted")
			}
		})
	}
}

func TestLogoutStopsRouteBeforeAccountLogoutAndPreservesGateIdentity(t *testing.T) {
	a := readyAgent()
	a.running = true
	a.publicURL = "https://boundas.example.ts.net/c2c/" + testID
	a.approvalURL = "https://login.tailscale.com/a/old"
	a.loginURL = "https://login.tailscale.com/a/old"
	called := false
	a.logout = func(context.Context) error {
		called = true
		if a.running || a.publicURL != "" {
			t.Fatal("route still active when logging out")
		}
		a.statusSource = func(context.Context) (*statusData, error) {
			return &statusData{state: "NeedsLogin", userspace: true}, nil
		}
		return nil
	}
	out := httptest.NewRecorder()
	a.control(out, httptest.NewRequest("POST", "http://localhost/logout", nil))
	var reply statusReply
	if err := json.Unmarshal(out.Body.Bytes(), &reply); err != nil {
		t.Fatal(err)
	}
	if !called || out.Code != 200 || reply.State != "login" || reply.Running || reply.ID != testID || a.approvalURL != "" || a.loginURL != "" {
		t.Fatal("logout did not safely close own Gate transport")
	}
	out = httptest.NewRecorder()
	a.control(out, httptest.NewRequest("GET", "http://localhost/logout", nil))
	if out.Code != 404 {
		t.Fatal("GET must not mutate account")
	}
}

func TestFailedLogoutLeavesRouteClosedAndCanRetry(t *testing.T) {
	a := readyAgent()
	a.running = true
	a.logout = func(context.Context) error { return errors.New("private credential failure") }
	out := httptest.NewRecorder()
	a.control(out, httptest.NewRequest("POST", "http://localhost/logout", nil))
	if out.Code != 409 || a.running || strings.Contains(out.Body.String(), "private credential") {
		t.Fatal("unsafe failed logout")
	}
	a.logout = func(context.Context) error { return nil }
	out = httptest.NewRecorder()
	a.control(out, httptest.NewRequest("POST", "http://localhost/logout", nil))
	if out.Code != 200 {
		t.Fatal("logout retry failed")
	}
}

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
	port, core := gateFixture(t, testID, strings.Repeat("a", 64))
	defer core.Close()
	otherPort, otherCore := gateFixture(t, testID, strings.Repeat("b", 64))
	defer otherCore.Close()
	call := func(route, body string) *httptest.ResponseRecorder {
		out := httptest.NewRecorder()
		a.control(out, httptest.NewRequest("POST", "http://localhost"+route, strings.NewReader(body)))
		return out
	}
	first := call("/start", fmt.Sprintf(`{"port":%d}`, port))
	if first.Code != 200 || !a.running {
		t.Fatal(first.Body.String())
	}
	url := a.publicURL
	if call("/stop", `{}`).Code != 200 || a.running {
		t.Fatal("stop failed")
	}
	if call("/start", fmt.Sprintf(`{"port":%d}`, otherPort)).Code != 200 || a.publicURL != url {
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

func TestSignInResumesLoggedOutNodeAfterWatchingAndBeforeInteractiveLogin(t *testing.T) {
	a := readyAgent()
	a.statusSource = func(context.Context) (*statusData, error) { return &statusData{state: "Stopped", userspace: true}, nil }
	u := "https://login.tailscale.com/a/retry"
	w := &testLoginNotifications{events: []ipn.Notify{{BrowseToURL: &u}}}
	var calls []string
	err := a.signIn(context.Background(), func(context.Context) (loginNotifications, error) {
		calls = append(calls, "watch")
		return w, nil
	}, func(context.Context) error { calls = append(calls, "resume"); return nil },
		func(context.Context) error { calls = append(calls, "login"); return nil })
	if err != nil || strings.Join(calls, ",") != "watch,resume,login" || a.status(context.Background()).LoginURL != u {
		t.Fatal("stopped-node login did not resume safely")
	}
	a.loginURL = ""
	called := false
	err = a.signIn(context.Background(), func(context.Context) (loginNotifications, error) { return w, nil },
		func(context.Context) error { return errors.New("resume failed") },
		func(context.Context) error { called = true; return nil })
	if err == nil || called || a.loginURL != "" {
		t.Fatal("failed resume continued login")
	}
}

func TestLoginFailureReportsReasonAndBackendStateWithoutVPNGuess(t *testing.T) {
	for _, item := range []struct {
		err  error
		code string
	}{
		{context.DeadlineExceeded, "login_timeout"}, {errInvalidLoginURL, "login_url_invalid"},
		{errLoginRejected, "login_rejected"}, {errors.New("secret upstream detail"), "login_failed"},
	} {
		a := readyAgent()
		a.statusSource = func(context.Context) (*statusData, error) { return &statusData{state: "Stopped", userspace: true}, nil }
		a.login = func(context.Context) error { return item.err }
		out := httptest.NewRecorder()
		a.control(out, httptest.NewRequest("POST", "http://localhost/login", nil))
		var reply struct{ ErrorCode, BackendState, Message string }
		if err := json.Unmarshal(out.Body.Bytes(), &reply); err != nil {
			t.Fatal(err)
		}
		if out.Code != 409 || reply.ErrorCode != item.code || reply.BackendState != "Stopped" || strings.Contains(reply.Message, "VPN") || strings.Contains(out.Body.String(), "secret") {
			t.Fatal("login failure is misreported or leaks provider detail")
		}
	}
}
