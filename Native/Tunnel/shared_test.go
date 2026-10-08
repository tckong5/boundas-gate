package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func gateFixture(t *testing.T, id, nonce string) (int, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			_ = json.NewEncoder(w).Encode(map[string]string{"service": "c2c-bridge", "workspaceId": id, "instanceID": nonce, "status": "ok"})
			return
		}
		if r.Header.Get("X-Boundas-Gate-Instance") != nonce {
			http.Error(w, "wrong lifetime", 409)
			return
		}
		if r.Header.Get("X-Forwarded-For") != "" {
			t.Error("untrusted client identity forwarded")
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"gate": id, "path": r.URL.Path, "query": r.URL.RawQuery, "authorization": r.Header.Get("Authorization")})
	}))
	var port int
	_, _ = fmt.Sscanf(strings.TrimPrefix(server.URL, "http://127.0.0.1:"), "%d", &port)
	return port, server
}

func TestSharedIngressRoutesDiscoveryOAuthAndMCPToSeparateGates(t *testing.T) {
	a := readyAgent()
	defer a.stop()
	listeners := 0
	a.listen = func() (net.Listener, error) { listeners++; return net.Listen("tcp", "127.0.0.1:0") }
	ids := []string{testID, "aaaaaa123456", "bbbbbb123456"}
	call := func(route string, body any) *httptest.ResponseRecorder {
		bytes, _ := json.Marshal(body)
		out := httptest.NewRecorder()
		a.control(out, httptest.NewRequest("POST", "http://localhost"+route, strings.NewReader(string(bytes))))
		return out
	}
	for _, id := range ids {
		port, core := gateFixture(t, id, strings.Repeat(id[:1], 64))
		defer core.Close()
		out := call("/routes/start", map[string]any{"gateID": id, "instanceID": strings.Repeat(id[:1], 64), "port": port})
		if out.Code != 200 {
			t.Fatal(out.Body.String())
		}
	}
	if listeners != 1 {
		t.Fatal("each Gate started a separate Tunnel")
	}
	for _, id := range ids {
		base := ""
		if id != testID {
			base = "/side/" + id
		}
		paths := map[string]string{base + "/mcp": "/mcp", base + "/oauth/register": "/oauth/register", base + "/oauth/authorize": "/oauth/authorize", base + "/oauth/token": "/oauth/token",
			base + "/.well-known/oauth-protected-resource/mcp": "/.well-known/oauth-protected-resource/mcp"}
		if base != "" {
			paths["/.well-known/oauth-authorization-server"+base] = "/.well-known/oauth-authorization-server"
			paths["/.well-known/oauth-protected-resource"+base+"/mcp"] = "/.well-known/oauth-protected-resource/mcp"
		}
		for public, local := range paths {
			req := httptest.NewRequest("POST", "https://boundas.example.ts.net"+public+"?resource=test", nil)
			req.Header.Set("Authorization", "Bearer own-gate")
			req.Header.Set("X-Forwarded-For", "forged")
			req.Header.Set("X-Boundas-Gate-Instance", "forged")
			out := httptest.NewRecorder()
			a.sharedHandler().ServeHTTP(out, req)
			var value map[string]string
			_ = json.Unmarshal(out.Body.Bytes(), &value)
			if out.Code != 200 || value["gate"] != id || value["path"] != local || value["authorization"] != "Bearer own-gate" || value["query"] != "resource=test" {
				t.Fatalf("wrong route: %s %s", public, out.Body.String())
			}
		}
	}
	for _, forbidden := range []string{"/control/activity", "/c2c/" + testID + "/control/activity", "/side/aaaaaa123456/control/activity", "/side/aaaaaa123456/control/info", "/side/aaaaaa123456/admin/info", "/side/cccccc123456/mcp", "/side/aaaaaa123456/%6dcp", "/side/aaaaaa123456/../mcp", "/control/info"} {
		out := httptest.NewRecorder()
		a.sharedHandler().ServeHTTP(out, httptest.NewRequest("GET", "https://boundas.example.ts.net"+forbidden, nil))
		if out.Code != 404 {
			t.Fatalf("public admin/alias accepted: %s", forbidden)
		}
	}
	// A stale daemon cannot stop the replacement's route.
	if call("/routes/stop", map[string]any{"gateID": ids[1], "instanceID": strings.Repeat("f", 64)}).Code != 409 {
		t.Fatal("stale stop accepted")
	}
	if call("/routes/stop", map[string]any{"gateID": ids[1], "instanceID": strings.Repeat("a", 64)}).Code != 200 {
		t.Fatal("Side close failed")
	}
	if call("/stop", map[string]any{}).Code != 200 {
		t.Fatal("Main close failed")
	}
	out := httptest.NewRecorder()
	a.sharedHandler().ServeHTTP(out, httptest.NewRequest("GET", "https://boundas.example.ts.net/side/"+ids[2]+"/mcp", nil))
	if out.Code != 200 || listeners != 1 {
		t.Fatal("closing Main or Side A broke Side B")
	}
	if call("/routes/stop", map[string]any{"gateID": ids[2], "instanceID": strings.Repeat("b", 64)}).Code != 200 || a.web != nil {
		t.Fatal("last route cleanup failed")
	}
}

func TestSharedRouteRejectsWrongRuntimeAndPortReuse(t *testing.T) {
	a := readyAgent()
	defer a.stop()
	port, core := gateFixture(t, "aaaaaa123456", strings.Repeat("a", 64))
	defer core.Close()
	for _, body := range []string{
		fmt.Sprintf(`{"gateID":"bbbbbb123456","instanceID":"%s","port":%d}`, strings.Repeat("b", 64), port),
		fmt.Sprintf(`{"gateID":"aaaaaa123456","instanceID":"%s","port":%d,"expectedURL":"https://evil.test/side/aaaaaa123456"}`, strings.Repeat("a", 64), port),
		fmt.Sprintf(`{"gateID":"aaaaaa123456","instanceID":"%s","port":%d,"url":"http://evil.test"}`, strings.Repeat("a", 64), port),
	} {
		out := httptest.NewRecorder()
		a.control(out, httptest.NewRequest("POST", "http://localhost/routes/start", strings.NewReader(body)))
		if out.Code == 200 || a.web != nil {
			t.Fatal("invalid target changed shared Tunnel")
		}
	}
	// Per-request identity guard rejects a stale local lifetime, even while the
	// listener remains available; a different Gate cannot inherit its URL.
	if err := a.startRoute(gateRoute{GateID: "aaaaaa123456", Port: port, InstanceID: strings.Repeat("b", 64)}); err != nil {
		t.Fatal(err)
	}
	out := httptest.NewRecorder()
	a.sharedHandler().ServeHTTP(out, httptest.NewRequest("GET", "https://boundas.example.ts.net/side/aaaaaa123456/mcp", nil))
	if out.Code != 502 {
		t.Fatal("port-reused lifetime accepted")
	}
}
