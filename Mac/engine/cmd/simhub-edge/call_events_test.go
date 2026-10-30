package main

import (
	"context"
	"github.com/cellbridge/cellbridge/gateway/internal/db"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

func TestCallReportDoesNotWaitForCloudAndPersistsInOrder(t *testing.T) {
	database, err := db.Open(filepath.Join(t.TempDir(), "events.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	database.Exec("CREATE TABLE edge_call_events(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT,status TEXT)")
	started := make(chan struct{}, 1)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		started <- struct{}{}
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer server.Close()
	defer close(release)
	e := &engine{database: database, boot: bootstrap{Origin: server.URL}, client: server.Client(), callEventWake: make(chan struct{}, 1)}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { defer close(done); e.callEventLoop(ctx) }()
	defer func() { cancel(); <-done }()
	e.callEvent("call", "connected")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("report worker did not start")
	}
	before := time.Now()
	e.callEvent("call", "ended")
	if time.Since(before) > 200*time.Millisecond {
		t.Fatal("call end blocked on cloud")
	}
	rows, err := database.Query("SELECT status FROM edge_call_events ORDER BY seq")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var states []string
	for rows.Next() {
		var s string
		rows.Scan(&s)
		states = append(states, s)
	}
	if len(states) != 2 || states[0] != "connected" || states[1] != "ended" {
		t.Fatalf("not durable or ordered: %v", states)
	}
}
func TestConnectedMonitorDetectsMissingCallWithoutURC(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stop := watchConnectedCall(ctx, cancel, func(context.Context) (bool, error) { return false, nil })
	defer stop()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("missing cellular call left SIP alive")
	}
}
