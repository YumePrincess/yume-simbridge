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
