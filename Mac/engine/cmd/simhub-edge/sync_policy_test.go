package main

import (
	"context"
	"github.com/gobwas/ws/wsutil"
	"net"
	"testing"
	"time"
)

func TestIdleCloudSyncReducesDailyPollsWithoutLosingTransitions(t *testing.T) {
	var policy syncPolicy
	state := cloudSyncState{Connected: true, Voice: true, SIP: true, SIM: "ready", Registration: "registered"}
	start := time.Now()
	count := 0
	for elapsed := time.Duration(0); elapsed < 24*time.Hour; elapsed += 5 * time.Second {
		now := start.Add(elapsed)
		if policy.due(now, state, false) {
			count++
			policy.complete(now, state, true, false)
		}
	}
	if count != 2880 {
		t.Fatalf("idle requests/day=%d", count)
	}
	var transition syncPolicy
	transition.complete(start, state, true, false)
	state.Connected = false
	if !transition.due(start.Add(5*time.Second), state, false) {
		t.Fatal("disconnect delayed until heartbeat")
	}
}
func TestCloudSyncWakeRetryBackoffAndQueueDrain(t *testing.T) {
	var p syncPolicy
	state := cloudSyncState{}
	now := time.Now()
	p.complete(now, state, true, false)
	if !p.due(now.Add(5*time.Second), state, true) {
		t.Fatal("queued work did not bypass heartbeat")
	}
	p.complete(now, state, false, false)
	p.complete(now.Add(5*time.Second), state, false, false)
	if p.due(now.Add(10*time.Second), state, true) {
		t.Fatal("wake bypassed failure backoff")
	}
	if !p.due(now.Add(15*time.Second), state, false) {
		t.Fatal("retry never becomes due")
	}
	p.complete(now.Add(15*time.Second), state, true, true)
	if !p.due(now.Add(20*time.Second), state, false) {
		t.Fatal("queued jobs not drained promptly")
	}
}
func TestCloudWakeDeliversWithoutPollingAndStopsOnCancel(t *testing.T) {
	client, server := net.Pipe()
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	e := &engine{wakeCh: make(chan struct{}, 1)}
	done := make(chan error, 1)
	go func() { done <- e.readCloudWake(ctx, client, nil) }()
	if err := wsutil.WriteServerText(server, []byte("wake")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-e.wakeCh:
	case <-time.After(time.Second):
		t.Fatal("push did not wake sync")
	}
	if !e.jobWake.Load() {
		t.Fatal("push did not request a queue claim")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("wake reader did not close")
	}
}
