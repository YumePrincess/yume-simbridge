package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"time"
)

func writeHealth(path string, value any) {
	b, err := json.Marshal(value)
	if err != nil {
		return
	}
	if os.WriteFile(path+".tmp", b, 0600) == nil {
		_ = os.Rename(path+".tmp", path)
	}
}
func audioHealthy(path string, now time.Time) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var h struct {
		Updated int64 `json:"updated"`
		Ready   bool  `json:"ready"`
	}
	if json.Unmarshal(b, &h) != nil {
		return false
	}
	age := now.UnixMilli() - h.Updated
	return h.Ready && age >= 0 && age < 4000
}

// Route reset failure used to latch voiceReady=false forever. Recover only
// while idle and with the real FIFOs present; startup without CoreAudio is
// handled by the supervisor. Reuse the call reservation to avoid dial races.
func (e *engine) tryRecoverVoice() {
	if e.rxPath == "" || e.txPath == "" || e.voiceReady.Load() || !e.busy.CompareAndSwap(false, true) {
		return
	}
	defer e.busy.Store(false)
	slog.Info("retrying failed module voice route while idle")
	e.resetRoute()
}
func (e *engine) voiceRecoveryLoop(ctx context.Context) {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			e.tryRecoverVoice()
		}
	}
}

func (e *engine) callActive() bool { e.callMu.Lock(); defer e.callMu.Unlock(); return e.callID != "" }
func (e *engine) healthSnapshot() map[string]any {
	e.healthMu.Lock()
	defer e.healthMu.Unlock()
	h := map[string]any{}
	for k, v := range e.healthBase {
		h[k] = v
	}
	connected, _ := h["modemConnected"].(bool)
	h["voiceReady"] = connected && e.voiceReady.Load() && audioHealthy(filepath.Join(e.healthDir, "audio-health.json"), time.Now())
	h["sipRegistered"] = e.registered.Load()
	h["busy"] = connected && e.callActive()
	h["version"] = Version + " (" + Build + ")"
	h["updated"] = time.Now().UnixMilli()
	h["heartbeatSeconds"] = 30
	h["cloudSyncCount"] = e.cloudSyncCount.Load()
	h["cloudPushConnected"] = e.wakeConnected.Load()
	return h
}
func (e *engine) localProbeLoop(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		if !e.busy.Load() {
			probe, cancel := context.WithTimeout(ctx, 2*time.Second)
			status, err := e.modem.Status(probe)
			cancel()
			if err != nil && e.busy.Load() {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
				}
				continue
			}
			e.healthMu.Lock()
			e.healthBase = map[string]any{"modemConnected": err == nil, "sim": status.SIM, "operator": status.Operator, "registration": status.Registration, "signal": status.Signal}
			e.healthMu.Unlock()
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
func (e *engine) localHealthLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		writeHealth(filepath.Join(e.healthDir, "edge-health.json"), e.healthSnapshot())
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
