package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
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
