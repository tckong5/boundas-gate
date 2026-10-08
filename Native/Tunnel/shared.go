package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// The shared ingress owns transport only. Each route still points to a separate
// Gate core, AuthStore and local lifetime. Instance IDs prevent port-reuse leaks.
type gateRoute struct {
	GateID     string `json:"gateID"`
	Port       int    `json:"port"`
	InstanceID string `json:"instanceID,omitempty"`
	PublicURL  string `json:"publicUrl"`
}

var validInstance = regexp.MustCompile(`^[a-f0-9]{64}$`)

func inspectGate(ctx context.Context, route gateRoute) (string, error) {
	request, err := http.NewRequestWithContext(ctx, "GET", fmt.Sprintf("http://127.0.0.1:%d/health", route.Port), nil)
	if err != nil {
		return "", err
	}
	client := &http.Client{Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	var health struct {
		Service     string
		WorkspaceID string `json:"workspaceId"`
		InstanceID  string
		Status      string
	}
	if response.StatusCode != 200 || json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&health) != nil ||
		(health.Service != "boundas-gateway" && health.Service != "c2c-bridge") || health.WorkspaceID != route.GateID || !validInstance.MatchString(health.InstanceID) ||
		(route.InstanceID != "" && health.InstanceID != route.InstanceID) || health.Status != "ok" {
		return "", errors.New("Gate runtime identity mismatch")
	}
	return health.InstanceID, nil
}
func verifyGate(ctx context.Context, route gateRoute) error {
	_, err := inspectGate(ctx, route)
	return err
}

func (a *agent) startRoute(route gateRoute) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.routes == nil {
		a.routes = make(map[string]gateRoute)
	}
	if len(a.routes) >= 256 {
		if _, exists := a.routes[route.GateID]; !exists {
			return errors.New("Too many Gate routes")
		}
	}
	if a.web == nil {
		ln, err := a.listen()
		if err != nil {
			return err
		}
		web := &http.Server{Handler: a.sharedHandler(), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second}
		a.listener, a.web = ln, web
		go func() {
			_ = web.Serve(ln)
			a.mu.Lock()
			if a.web == web {
				a.running = false
				a.routes = nil
				a.web = nil
				a.listener = nil
				a.publicURL = ""
			}
			a.mu.Unlock()
		}()
	}
	a.routes[route.GateID] = route
	if route.GateID == a.id {
		a.running = true
		a.publicURL = route.PublicURL
	}
	return nil
}

func (a *agent) removeRoute(id, instance string) bool {
	a.mu.Lock()
	route, exists := a.routes[id]
	if exists && instance != "" && route.InstanceID != instance {
		a.mu.Unlock()
		return false
	}
	delete(a.routes, id)
	if id == a.id {
		a.running = false
		a.publicURL = ""
	}
	// Closing a Gate never closes the remaining Gates' shared listener.
	var web *http.Server
	if len(a.routes) == 0 {
		web = a.web
		a.web = nil
		a.listener = nil
	}
	a.mu.Unlock()
	if web != nil {
		_ = web.Close()
	}
	return true
}

func routePath(mainID, gateID, raw string) (string, bool) {
	if gateID == mainID {
		if p, ok := publicPath(gateID, raw); ok {
			return p, true
		} // Existing Main URLs remain valid.
		return publicPath(gateID, "/c2c/"+gateID+raw)
	}
	base := "/side/" + gateID
	aliases := map[string]string{
		"/.well-known/oauth-authorization-server" + base:        "/.well-known/oauth-authorization-server",
		"/.well-known/openid-configuration" + base:              "/.well-known/openid-configuration",
		"/.well-known/oauth-protected-resource" + base + "/mcp": "/.well-known/oauth-protected-resource/mcp",
	}
	if p, ok := aliases[raw]; ok {
		return p, true
	}
	if !strings.HasPrefix(raw, base+"/") {
		return "", false
	}
	return publicPath(gateID, "/c2c/"+gateID+strings.TrimPrefix(raw, base))
}

func (a *agent) sharedHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.RawPath != "" || strings.Contains(r.URL.EscapedPath(), "%") {
			http.NotFound(w, r)
			return
		}
		a.mu.Lock()
		var target gateRoute
		var localPath string
		for id, route := range a.routes {
			if p, ok := routePath(a.id, id, r.URL.Path); ok {
				target, localPath = route, p
				break
			}
		}
		a.mu.Unlock()
		if target.GateID == "" {
			http.NotFound(w, r)
			return
		}
		if target.InstanceID != "" {
			ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
			err := verifyGate(ctx, target)
			cancel()
			if err != nil {
				http.Error(w, "Gate unavailable", http.StatusBadGateway)
				return
			}
		}
		// Reuse the existing strict public-only proxy and header sanitization.
		r.URL.Path = "/c2c/" + target.GateID + localPath
		r.Header.Del("X-Boundas-Gate-Instance")
		if target.InstanceID != "" {
			r.Header.Set("X-Boundas-Gate-Instance", target.InstanceID)
		}
		publicHandler(target.GateID, target.Port).ServeHTTP(w, r)
	})
}

func (a *agent) routeControl(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" || (r.URL.Path != "/routes/start" && r.URL.Path != "/routes/stop") {
		http.NotFound(w, r)
		return
	}
	a.op.Lock()
	defer a.op.Unlock()
	var input struct {
		GateID      string `json:"gateID"`
		InstanceID  string `json:"instanceID"`
		Port        int    `json:"port"`
		ExpectedURL string `json:"expectedURL"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2048))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || !validID.MatchString(input.GateID) || !validInstance.MatchString(input.InstanceID) {
		replyJSON(w, 400, map[string]any{"ok": false, "message": "Invalid Gate route"})
		return
	}
	if r.URL.Path == "/routes/stop" {
		if !a.removeRoute(input.GateID, input.InstanceID) {
			replyJSON(w, 409, map[string]any{"ok": false, "message": "Gate runtime has changed"})
			return
		}
		replyJSON(w, 200, map[string]bool{"ok": true})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	state := a.status(ctx)
	if state.State != "ready" {
		state.OK = false
		replyJSON(w, 409, state)
		return
	}
	expected := "https://" + state.Hostname
	if input.GateID != a.id {
		expected += "/side/" + input.GateID
	}
	if input.GateID == a.id && input.ExpectedURL == expected+"/c2c/"+a.id {
		expected = input.ExpectedURL
	}
	route := gateRoute{GateID: input.GateID, Port: input.Port, InstanceID: input.InstanceID, PublicURL: expected}
	if input.Port < 1 || input.Port > 65535 || input.ExpectedURL != "" && input.ExpectedURL != expected {
		replyJSON(w, 400, map[string]any{"ok": false, "message": "Invalid Gate endpoint"})
		return
	}
	if verifyGate(ctx, route) != nil {
		replyJSON(w, 409, map[string]any{"ok": false, "message": "Gate runtime identity mismatch"})
		return
	}
	if err := a.startRoute(route); err != nil {
		replyJSON(w, 409, map[string]any{"ok": false, "message": "Shared secure access could not start"})
		return
	}
	replyJSON(w, 200, map[string]any{"ok": true, "publicUrl": expected})
}
