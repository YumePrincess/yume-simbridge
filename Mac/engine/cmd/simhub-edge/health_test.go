package main

import (
	"path/filepath"
	"testing"
	"time"
)

func TestAudioHealthRequiresFreshSuccessfulProbe(t *testing.T) {
	p := filepath.Join(t.TempDir(), "health.json")
	now := time.Now()
	if audioHealthy(p, now) {
		t.Fatal("missing health must not be ready")
	}
	for _, tc := range []struct {
		age         int64
		ready, want bool
	}{{0, true, true}, {5000, true, false}, {0, false, false}, {-5000, true, false}} {
		writeHealth(p, map[string]any{"updated": now.UnixMilli() - tc.age, "ready": tc.ready})
		if got := audioHealthy(p, now); got != tc.want {
			t.Fatalf("age=%d ready=%v got=%v", tc.age, tc.ready, got)
		}
	}
}

func TestFailedRouteRecoversOnIdleRetryWithoutStartingAnotherCall(t *testing.T) {
	e := &engine{rxPath: "rx", txPath: "tx", routeScript: "unused", python: "/usr/bin/false"}
	e.tryRecoverVoice()
	if e.voiceReady.Load() || e.busy.Load() {
		t.Fatal("failed reset reported ready or kept line busy")
	}
	e.python = "/usr/bin/true"
	e.tryRecoverVoice()
	if !e.voiceReady.Load() || e.busy.Load() {
		t.Fatal("idle retry did not restore actual route result")
	}
	e.voiceReady.Store(false)
	e.busy.Store(true)
	e.tryRecoverVoice()
	if e.voiceReady.Load() || !e.busy.Load() {
		t.Fatal("recovery interfered with active call")
	}
	e.busy.Store(false)
	e.rxPath = ""
	e.tryRecoverVoice()
	if e.voiceReady.Load() {
		t.Fatal("cannot declare ready without audio FIFO")
	}
}
