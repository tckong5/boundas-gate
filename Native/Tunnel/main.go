package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

var validID = regexp.MustCompile(`^[a-f0-9]{12}$`)
var validHostname = regexp.MustCompile(`^[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net$`)

type statusData struct {
	state, hostname, loginURL              string
	userspace, funnelAllowed, httpsEnabled bool
}
type statusReply struct {
	AccountManagementVersion int    `json:"accountManagementVersion"`
	OK                       bool   `json:"ok"`
	Service                  string `json:"service"`
	ID                       string `json:"gatewayID"`
	State                    string `json:"state"`
	Message                  string `json:"message"`
	Hostname                 string `json:"hostname,omitempty"`
	LoginURL                 string `json:"loginURL,omitempty"`
	ApprovalURL              string `json:"approvalURL,omitempty"`
	Running                  bool   `json:"running"`
	Userspace                bool   `json:"userspace"`
	PublicURL                string `json:"publicUrl,omitempty"`
	PID                      int    `json:"pid"`
}
type agent struct {
	id          string
	node        *tsnet.Server
	client      *local.Client
	mu          sync.Mutex
	op          sync.Mutex
	listener    net.Listener
	web         *http.Server
	running     bool
	publicURL   string
	approvalURL string
	// Unit tests use a local status provider; production always uses tsnet.
	statusSource func(context.Context) (*statusData, error)
	listen       func() (net.Listener, error)
	login        func(context.Context) error
	logout       func(context.Context) error
}

func (a *agent) status(ctx context.Context) statusReply {
	reply := statusReply{OK: true, Service: "boundas-tsnet", ID: a.id, PID: os.Getpid(), AccountManagementVersion: 1}
	data, err := a.statusSource(ctx)
	if err != nil {
		reply.State = "starting"
		reply.Message = "內置連線正在準備，請稍後再檢查。"
		return reply
	}
	reply.Userspace = data.userspace
	if !data.userspace {
		reply.State = "blocked"
		reply.Message = "內置連線模式無效，未有開啟公開入口。"
		return reply
	}
	reply.Hostname = data.hostname
	if data.state != "Running" {
		reply.State = "login"
		reply.Message = "請登入內置 Tailscale 連線。"
		if u, e := url.Parse(data.loginURL); e == nil && u.Scheme == "https" && u.Host == "login.tailscale.com" && u.User == nil {
			reply.LoginURL = u.String()
		}
		if data.state == "NeedsMachineAuth" {
			reply.Message = "請喺 Tailscale 管理頁允許呢個裝置。"
			reply.ApprovalURL = "https://login.tailscale.com/admin/machines"
		}
		return reply
	}
	if !validHostname.MatchString(data.hostname) {
		reply.State = "blocked"
		reply.Message = "請喺 Tailscale 啟用 MagicDNS。"
		reply.ApprovalURL = "https://login.tailscale.com/admin/dns"
		return reply
	}
	if !data.httpsEnabled || !data.funnelAllowed {
		reply.State = "blocked"
		reply.Message = "請允許 Tailscale HTTPS／Funnel 公開連線。"
		a.mu.Lock()
		reply.ApprovalURL = a.approvalURL
		a.mu.Unlock()
		return reply
	}
	reply.State = "ready"
	reply.Message = "內置連線已登入。"
	a.mu.Lock()
	reply.Running = a.running && a.publicURL == "https://"+data.hostname+"/c2c/"+a.id
	reply.PublicURL = a.publicURL
	a.mu.Unlock()
	return reply
}

// Only MCP, OAuth, discovery and health are exposed. The helper accepts a local
// port, never a caller-supplied URL or path. Admin/control routes never pass.
func publicPath(id, raw string) (string, bool) {
	base := "/c2c/" + id
	routes := map[string]string{
		"/.well-known/oauth-authorization-server/c2c/" + id:        "/.well-known/oauth-authorization-server",
		"/.well-known/openid-configuration/c2c/" + id:              "/.well-known/openid-configuration",
		"/.well-known/oauth-protected-resource/c2c/" + id + "/mcp": "/.well-known/oauth-protected-resource/mcp",
	}
	for _, p := range []string{"/health", "/mcp", "/oauth/register", "/oauth/authorize", "/oauth/token", "/oauth/revoke", "/.well-known/oauth-authorization-server", "/.well-known/oauth-authorization-server/mcp", "/.well-known/openid-configuration", "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"} {
		routes[base+p] = p
	}
	p, ok := routes[raw]
	return p, ok
}
func publicHandler(id string, port int) http.Handler {
	proxy := &httputil.ReverseProxy{Director: func(r *http.Request) {
		r.URL.Scheme = "http"
		r.URL.Host = fmt.Sprintf("127.0.0.1:%d", port)
		r.Host = r.URL.Host
		for _, h := range []string{"Forwarded", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "Proxy-Authorization", "Proxy-Connection"} {
			r.Header.Del(h)
		}
		r.Header.Set("X-Forwarded-Proto", "https")
	}, FlushInterval: -1, ErrorLog: log.New(os.Stderr, "proxy: ", 0), ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
		http.Error(w, "Connection unavailable", http.StatusBadGateway)
	}}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Reject encoded aliases and traversal before path rewriting.
		if r.URL.RawPath != "" || strings.Contains(r.URL.EscapedPath(), "%") {
			http.NotFound(w, r)
			return
		}
		p, ok := publicPath(id, r.URL.Path)
		if !ok {
			http.NotFound(w, r)
			return
		}
		r.URL.Path = p
		r.URL.RawPath = ""
		proxy.ServeHTTP(w, r)
	})
}
func replyJSON(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(value)
}
func (a *agent) stop() {
	a.mu.Lock()
	web, ln := a.web, a.listener
	a.web = nil
	a.listener = nil
	a.running = false
	a.publicURL = ""
	a.mu.Unlock()
	if web != nil {
		_ = web.Close()
	}
	if ln != nil {
		_ = ln.Close()
	}
}
func (a *agent) control(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/status" && r.Method == http.MethodGet {
		ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
		defer cancel()
		replyJSON(w, 200, a.status(ctx))
		return
	}
	if (r.URL.Path == "/login" || r.URL.Path == "/logout") && r.Method == http.MethodPost {
		a.op.Lock()
		defer a.op.Unlock()
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()
		action := a.login
		if r.URL.Path == "/logout" {
			action = a.logout
		}
		if action == nil {
			http.NotFound(w, r)
			return
		}
		if r.URL.Path == "/logout" {
			a.stop()
			a.mu.Lock()
			a.approvalURL = ""
			a.mu.Unlock()
		}
		if err := action(ctx); err != nil {
			replyJSON(w, 409, map[string]any{"ok": false, "message": "未能完成 Tunnel 登入／登出，請稍後再試。"})
			return
		}
		replyJSON(w, 200, a.status(ctx))
		return
	}
	if r.URL.Path == "/approve" && r.Method == http.MethodPost {
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()
		if a.client == nil {
			http.NotFound(w, r)
			return
		}
		info, err := a.client.QueryFeature(ctx, "funnel")
		if err != nil {
			replyJSON(w, 409, map[string]any{"ok": false, "message": "未能開啟公開連線授權頁，請稍後再試。"})
			return
		}
		if u, e := url.Parse(info.URL); e == nil && u.Scheme == "https" && u.Host == "login.tailscale.com" && u.User == nil {
			a.mu.Lock()
			a.approvalURL = u.String()
			a.mu.Unlock()
		}
		replyJSON(w, 200, a.status(ctx))
		return
	}
	if r.Method != http.MethodPost || (r.URL.Path != "/start" && r.URL.Path != "/stop") {
		http.NotFound(w, r)
		return
	}
	a.op.Lock()
	defer a.op.Unlock()
	if r.URL.Path == "/stop" {
		a.stop()
		replyJSON(w, 200, map[string]bool{"ok": true})
		return
	}
	var input struct {
		Port        int    `json:"port"`
		ExpectedURL string `json:"expectedURL"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2048))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || input.Port < 1 || input.Port > 65535 {
		replyJSON(w, 400, map[string]any{"ok": false, "message": "Invalid local port"})
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
	expected := "https://" + state.Hostname + "/c2c/" + a.id
	if input.ExpectedURL != "" && input.ExpectedURL != expected {
		replyJSON(w, 409, map[string]any{"ok": false, "message": "固定地址同原有 ChatGPT 設定唔一致；未有更改地址或授權。"})
		return
	}
	a.stop()
	ln, err := a.listen()
	if err != nil {
		replyJSON(w, 409, map[string]any{"ok": false, "message": "內置公開連線未能啟動，請檢查 Tailscale HTTPS／Funnel 權限。"})
		return
	}
	web := &http.Server{Handler: publicHandler(a.id, input.Port), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second}
	a.mu.Lock()
	a.listener = ln
	a.web = web
	a.running = true
	a.publicURL = expected
	a.mu.Unlock()
	go func() {
		_ = web.Serve(ln)
		a.mu.Lock()
		if a.web == web {
			a.running = false
		}
		a.mu.Unlock()
	}()
	replyJSON(w, 200, map[string]any{"ok": true, "publicUrl": expected})
}
func serve(directory, id string) error {
	if !validID.MatchString(id) {
		return errors.New("Invalid gateway ID")
	}
	if !filepath.IsAbs(directory) {
		return errors.New("State directory must be absolute")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	if err := os.Chmod(directory, 0700); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(directory, "agent.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("Embedded agent is already running")
	}
	key := fmt.Sprintf("%x", sha256.Sum256([]byte(directory)))[:16]
	controlDirectory := fmt.Sprintf("/private/tmp/boundas-tsnet-%d-%s", os.Getuid(), key)
	if err = os.Mkdir(controlDirectory, 0700); err != nil && !os.IsExist(err) {
		return err
	}
	info, err := os.Lstat(controlDirectory)
	if err != nil {
		return err
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || info.Mode().Perm() != 0700 || !ok || owner.Uid != uint32(os.Getuid()) {
		return errors.New("Control directory is not private")
	}
	socket := filepath.Join(controlDirectory, "control.sock")
	_ = os.Remove(socket)
	ln, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer os.Remove(socket)
	defer ln.Close()
	if err = os.Chmod(socket, 0600); err != nil {
		return err
	}
	node := &tsnet.Server{Dir: filepath.Join(directory, "identity"), Hostname: "boundas-gate-" + id, UserLogf: func(string, ...any) {}, Logf: func(string, ...any) {}}
	if err = node.Start(); err != nil {
		return err
	}
	defer node.Close()
	client, err := node.LocalClient()
	if err != nil {
		return err
	}
	a := &agent{id: id, node: node, client: client}
	a.login = client.StartLoginInteractive
	a.logout = client.Logout
	a.statusSource = func(ctx context.Context) (*statusData, error) {
		st, e := client.Status(ctx)
		if e != nil {
			return nil, e
		}
		hostname := ""
		if st.Self != nil {
			hostname = strings.TrimSuffix(strings.ToLower(st.Self.DNSName), ".")
		}
		allowed := st.Self != nil && ipn.CheckFunnelAccess(443, st.Self) == nil
		return &statusData{state: st.BackendState, hostname: hostname, loginURL: st.AuthURL, userspace: !st.TUN, funnelAllowed: allowed, httpsEnabled: len(st.CertDomains) > 0}, nil
	}
	a.listen = func() (net.Listener, error) { return node.ListenFunnel("tcp", ":443", tsnet.FunnelOnly()) }
	control := &http.Server{Handler: http.HandlerFunc(a.control), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 15 * time.Second}
	signalChannel := make(chan os.Signal, 1)
	signal.Notify(signalChannel, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-signalChannel
		_ = node.Close()
		a.op.Lock()
		a.stop()
		a.op.Unlock()
		_ = control.Close()
	}()
	err = control.Serve(ln)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

// Manage the existing Mac device without creating a new login profile or
// altering its routing/DNS preferences. No account credentials leave LocalAPI.
func externalAuth(action string) error {
	if action != "login" && action != "logout" {
		return errors.New("Invalid Tunnel action")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	client := &local.Client{}
	if action == "logout" {
		if err := client.Logout(ctx); err != nil {
			return err
		}
	} else {
		st, err := client.Status(ctx)
		if err != nil {
			return err
		}
		if st.BackendState == "Stopped" {
			if _, err = client.EditPrefs(ctx, &ipn.MaskedPrefs{Prefs: ipn.Prefs{WantRunning: true}, WantRunningSet: true}); err != nil {
				return err
			}
		} else if st.BackendState == "NeedsLogin" || st.BackendState == "NoState" {
			if err = client.StartLoginInteractive(ctx); err != nil {
				return err
			}
		}
	}
	for attempt := 0; attempt < 30; attempt++ {
		st, err := client.Status(ctx)
		if err != nil {
			return err
		}
		result := map[string]any{"ok": true, "state": "login", "message": "請完成 Tunnel 登入，再重新檢查。"}
		if st.BackendState == "Running" {
			result["state"] = "ready"
			result["message"] = "Tunnel 已登入。"
		}
		if u, e := url.Parse(st.AuthURL); e == nil && u.Scheme == "https" && u.Host == "login.tailscale.com" && u.User == nil {
			result["loginURL"] = u.String()
		}
		if st.BackendState == "NeedsMachineAuth" {
			result["approvalURL"] = "https://login.tailscale.com/admin/machines"
		}
		if action == "logout" || result["state"] == "ready" || result["loginURL"] != nil || result["approvalURL"] != nil || attempt == 29 {
			return json.NewEncoder(os.Stdout).Encode(result)
		}
		time.Sleep(200 * time.Millisecond)
	}
	return nil
}
func main() {
	directory := flag.String("state-dir", "", "Private state directory")
	id := flag.String("gateway-id", "", "Gateway identity")
	version := flag.Bool("version", false, "Version information")
	external := flag.String("external-auth", "", "Manage the existing Mac Tunnel login")
	flag.Parse()
	if *version {
		fmt.Println("boundas-tsnet 1.2.0 / tailscale 1.104.0")
		return
	}
	if *external != "" {
		if err := externalAuth(*external); err != nil {
			_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": false, "message": "未能連接外置 Tailscale，請開啟 Tailscale 後重試。"})
			os.Exit(1)
		}
		return
	}
	if err := serve(*directory, *id); err != nil {
		fmt.Fprintln(os.Stderr, "Embedded tunnel could not start:", err)
		os.Exit(1)
	}
}
