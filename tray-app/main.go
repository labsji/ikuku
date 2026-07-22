package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/getlantern/systray"
)

const (
	appDir         = `C:\ikuku`
	statusFile     = `C:\ikuku\status.txt`
	confFile       = `C:\ikuku\ikuku.conf`
	configJSON     = `C:\ikuku\tray-config.json`
	logFile        = `C:\ikuku\install.log`
	notifyFile     = `C:\ikuku\notification.txt`
	healthURL      = "http://localhost:8000/api/method/frappe.ping"
	healthInterval = 60 * time.Second
)

// States
type AppState int

const (
	StateInstalling AppState = iota
	StateReady
	StateActive
	StateError
)

// TrayConfig from Kiro
type TrayConfig struct {
	Brand string     `json:"brand"`
	Icon  string     `json:"icon"`
	Menu  []MenuItem `json:"menu"`
}

type MenuItem struct {
	Label    string `json:"label"`
	Action   string `json:"action"`
	Disabled bool   `json:"disabled"`
}

// Config file
type Config struct {
	AuthEndpoint string
	Token        string
	InstallID    string
}

var (
	state      AppState
	stateMu    sync.Mutex
	conf       Config
	trayConfig *TrayConfig
	statusText string // last value read from status.txt
	mStatus    *systray.MenuItem
	mActivate  *systray.MenuItem
	mOpenERP   *systray.MenuItem
	mTalkKiro  *systray.MenuItem
	mRestart   *systray.MenuItem
	mViewLog   *systray.MenuItem
	mQuit      *systray.MenuItem
)

func main() {
	systray.Run(onReady, onExit)
}

func onReady() {
	systray.SetTitle("ikuku")
	systray.SetTooltip("ikuku — ERPNext")

	// Load initial state
	loadConfig()
	state = determineState()
	setIcon(state)

	// Default menu
	mStatus = systray.AddMenuItem("Status: Starting...", "")
	mStatus.Disable()
	systray.AddSeparator()
	mActivate = systray.AddMenuItem("Activate", "Enter activation code")
	mOpenERP = systray.AddMenuItem("Open ERPNext", "Open in browser")
	mTalkKiro = systray.AddMenuItem("Talk to Kiro", "Open AI assistant")
	mRestart = systray.AddMenuItem("Restart ERPNext", "Restart containers")
	systray.AddSeparator()
	mViewLog = systray.AddMenuItem("View Log", "Open install log")
	mQuit = systray.AddMenuItem("Exit", "Close tray app")

	updateMenu()

	// Start watchers
	go watchFiles()
	go healthCheck()
	go handleClicks()
}

func onExit() {
	// Cleanup
}

func handleClicks() {
	for {
		select {
		case <-mActivate.ClickedCh:
			doActivate()
		case <-mOpenERP.ClickedCh:
			openBrowser("http://localhost:8000")
		case <-mTalkKiro.ClickedCh:
			doTalkKiro()
		case <-mRestart.ClickedCh:
			doRestart()
		case <-mViewLog.ClickedCh:
			openNotepad(logFile)
		case <-mQuit.ClickedCh:
			systray.Quit()
		}
	}
}

func determineState() AppState {
	// Check status file first — it's authoritative
	data, err := os.ReadFile(statusFile)
	if err == nil {
		s := strings.TrimSpace(string(data))
		switch s {
		case "installing":
			return StateInstalling
		case "ready":
			return StateReady
		case "active":
			return StateActive
		case "error":
			return StateError
		}
	}

	// No status file — use token presence as hint
	if conf.Token != "" {
		return StateReady // amber — have token but not confirmed running
	}

	return StateInstalling
}

func updateMenu() {
	stateMu.Lock()
	defer stateMu.Unlock()

	switch state {
	case StateInstalling:
		mStatus.SetTitle("Status: Installing...")
		mActivate.Enable()
		mOpenERP.Disable()
		mTalkKiro.Disable()
		mRestart.Disable()
	case StateReady:
		mStatus.SetTitle("Status: Ready — activate to begin")
		mActivate.Enable()
		mOpenERP.Disable()
		mTalkKiro.Disable()
		mRestart.Disable()
	case StateActive:
		mStatus.SetTitle("Status: Running")
		mActivate.Disable()
		mOpenERP.Enable()
		mTalkKiro.Enable()
		mRestart.Enable()
	case StateError:
		mStatus.SetTitle("Status: Error — check log")
		mActivate.Enable()
		mOpenERP.Disable()
		mTalkKiro.Disable()
		mRestart.Enable()
	}

	setIcon(state)

	// Apply tray-config.json if present
	if trayConfig != nil && state == StateActive {
		applyTrayConfig()
	}
}

func setIcon(s AppState) {
	switch s {
	case StateInstalling:
		systray.SetIcon(iconGrey)
	case StateReady:
		systray.SetIcon(iconAmber)
	case StateActive:
		systray.SetIcon(iconGreen)
	case StateError:
		systray.SetIcon(iconRed)
	}
}

func loadConfig() {
	data, err := os.ReadFile(confFile)
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(strings.TrimRight(line, "\r"))
		if strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])
		switch key {
		case "AUTH_ENDPOINT":
			conf.AuthEndpoint = val
		case "TOKEN":
			conf.Token = val
		case "INSTALL_ID":
			conf.InstallID = val
		}
	}
	if conf.AuthEndpoint == "" {
		conf.AuthEndpoint = "https://auth.next.skith.in"
	}
}

func watchFiles() {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	var lastConfig, lastNotify string

	// Phase tooltip map
	tooltips := map[string]string{
		"waiting_containers": "ikuku - waiting for containers to start",
		"starting":           "ikuku - starting",
		"initializing":       "ikuku - initializing bench (1-2 min)",
		"installing_apps":    "ikuku - installing ERPNext apps",
		"building_assets":    "ikuku - building frontend (almost done)",
		"creating_site":      "ikuku - creating site and database",
		"activating_kiro":    "ikuku - activating AI assistant",
		"ready":             "ikuku - ready",
		"active":            "ikuku - ready",
		"installing":        "ikuku - installing",
		"error":             "ikuku - error (right-click > View Log)",
	}

	for range ticker.C {
		// Watch status.txt — always re-read and assert state
		if data, err := os.ReadFile(statusFile); err == nil {
			s := strings.TrimSpace(string(data))
			statusText = s
			// Update tooltip based on phase
			if tip, ok := tooltips[s]; ok {
				systray.SetTooltip(tip)
			}
			loadConfig()
			newState := determineState()
			if newState != state {
				state = newState
				updateMenu()
			}
		}

		// Independent readiness check: if still installing, poll ERPNext directly
		if state == StateInstalling || state == StateReady {
			resp, err := http.Get(healthURL)
			if err == nil {
				resp.Body.Close()
				if resp.StatusCode == 200 {
					// ERPNext is live — write status.txt and transition
					os.WriteFile(statusFile, []byte("active"), 0644)
					statusText = "active"
					state = StateActive
					systray.SetTooltip("ikuku - ready")
					updateMenu()
				}
			}
		}

		// Watch tray-config.json
		if data, err := os.ReadFile(configJSON); err == nil {
			s := string(data)
			if s != lastConfig {
				lastConfig = s
				var tc TrayConfig
				if json.Unmarshal(data, &tc) == nil {
					trayConfig = &tc
					if state == StateActive {
						updateMenu()
					}
				}
			}
		}

		// Watch notification.txt
		if data, err := os.ReadFile(notifyFile); err == nil {
			s := strings.TrimSpace(string(data))
			if s != "" && s != lastNotify {
				lastNotify = s
				systray.SetTooltip(s)
				// Remove after reading
				os.Remove(notifyFile)
			}
		}
	}
}

func healthCheck() {
	// Wait for active state
	for state != StateActive {
		time.Sleep(5 * time.Second)
	}

	// Wait for first successful ping before starting failure detection
	for {
		resp, err := http.Get(healthURL)
		if err == nil && resp.StatusCode == 200 {
			resp.Body.Close()
			break
		}
		time.Sleep(10 * time.Second)
	}

	ticker := time.NewTicker(healthInterval)
	defer ticker.Stop()

	for range ticker.C {
		if state != StateActive && state != StateError {
			continue
		}
		// If status.txt explicitly says "active", don't override to error
		if statusText == "active" || statusText == "installing" {
			if state == StateError {
				state = StateActive
				updateMenu()
			}
			continue
		}
		resp, err := http.Get(healthURL)
		if err != nil || resp.StatusCode != 200 {
			if state != StateError {
				state = StateError
				updateMenu()
			}
		} else {
			if state == StateError {
				state = StateActive
				updateMenu()
			}
			resp.Body.Close()
		}
	}
}

func doActivate() {
	if runtime.GOOS != "windows" {
		return
	}
	// Use PowerShell input box for activation code
	psCmd := `Add-Type -AssemblyName Microsoft.VisualBasic; $code = [Microsoft.VisualBasic.Interaction]::InputBox("Enter your activation code:", "ikuku Activation", ""); if ($code) { $code } else { "" }`
	out, err := exec.Command("powershell", "-Command", psCmd).Output()
	if err != nil {
		return
	}
	code := strings.TrimSpace(string(out))
	if code == "" {
		return
	}

	// Get machine ID
	machineID := getMachineID()
	installID := conf.InstallID
	if installID == "" {
		hostname, _ := os.Hostname()
		installID = "ikuku-" + hostname
	}

	// Register
	body := fmt.Sprintf(`{"otp":"%s","machine_id":"%s","install_id":"%s"}`, code, machineID, installID)
	resp, err := http.Post(conf.AuthEndpoint+"/register", "application/json", strings.NewReader(body))
	if err != nil {
		writeStatus("error")
		return
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	var result map[string]interface{}
	if json.Unmarshal(respBody, &result) != nil {
		writeStatus("error")
		return
	}

	token, ok := result["token"].(string)
	if !ok || token == "" {
		writeStatus("error")
		return
	}

	// Save token to config
	conf.Token = token
	saveToken(token)
	writeStatus("active")
	state = StateActive
	updateMenu()
}

func doTalkKiro() {
	if runtime.GOOS == "windows" {
		exec.Command("cmd", "/c", "start", "wsl.exe", "-u", "root", "--", "bash", "-c",
			"cd /opt/ikuku && bash activate.sh").Start()
	}
}

func doRestart() {
	if runtime.GOOS == "windows" {
		go func() {
			exec.Command("wsl.exe", "-u", "root", "--", "bash", "-c",
				"cd /opt/ikuku; podman-compose restart").Run()
		}()
	}
}

func openBrowser(url string) {
	if runtime.GOOS == "windows" {
		exec.Command("cmd", "/c", "start", url).Start()
	}
}

func openNotepad(path string) {
	if runtime.GOOS == "windows" {
		exec.Command("notepad.exe", path).Start()
	}
}

func getMachineID() string {
	if runtime.GOOS == "windows" {
		out, err := exec.Command("wmic", "csproduct", "get", "uuid").Output()
		if err == nil {
			lines := strings.Split(string(out), "\n")
			for _, l := range lines {
				l = strings.TrimSpace(l)
				if l != "" && l != "UUID" {
					return l
				}
			}
		}
	}
	hostname, _ := os.Hostname()
	return hostname
}

func writeStatus(s string) {
	os.MkdirAll(filepath.Dir(statusFile), 0755)
	os.WriteFile(statusFile, []byte(s+"\n"), 0644)
}

func saveToken(token string) {
	// Append/update TOKEN in ikuku.conf
	data, _ := os.ReadFile(confFile)
	lines := strings.Split(string(data), "\n")
	found := false
	for i, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "TOKEN=") {
			lines[i] = "TOKEN=" + token
			found = true
			break
		}
	}
	if !found {
		lines = append(lines, "TOKEN="+token)
	}
	os.WriteFile(confFile, []byte(strings.Join(lines, "\n")), 0644)
}

func applyTrayConfig() {
	// In a full implementation, this would dynamically rebuild menu items.
	// For v1, we update the tooltip with the brand name.
	if trayConfig.Brand != "" {
		systray.SetTooltip(trayConfig.Brand)
	}
}
