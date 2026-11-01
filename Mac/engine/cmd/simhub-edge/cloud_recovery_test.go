package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// A claimed SMS can be slow without starving lease health or claiming it twice.
func TestSyncContinuesWhileClaimedJobIsPending(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var health map[string]any
		if err := json.NewDecoder(r.Body).Decode(&health); err != nil {
			t.Error(err)
		}
		n := requests.Add(1)
		if health["claimJobs"] != (n == 1) {
			t.Errorf("request %d claimJobs=%v", n, health["claimJobs"])
		}
		if n == 1 {
			fmt.Fprint(w, `{"job":{"id":"one","payload":"{}"},"sip":{"domain":"registrar","user":"u","password":"p"}}`)
		} else {
			fmt.Fprint(w, `{}`)
		}
	}))
	defer server.Close()
	e := &engine{client: newCloudClient(), boot: bootstrap{Origin: server.URL}, healthDir: t.TempDir(), jobs: make(chan job, 1)}
	e.sync(context.Background())
	if !e.jobPending.Load() || len(e.jobs) != 1 {
		t.Fatal("job not reserved for worker")
	}
	e.cloudPolicy.attempted = time.Now().Add(-time.Minute)
	e.cloudPolicy.next = time.Now().Add(-time.Second)
	e.sync(context.Background()) // No modem/database: heartbeat must not do SMS I/O.
	if requests.Load() != 2 || !e.jobPending.Load() {
		t.Fatal("pending job blocked heartbeat or lost its reservation")
	}
}

func TestCloudFailurePreservesSIPAndRecoversOnNewPushConnection(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		fmt.Fprint(w, `{"sip":{"domain":"registrar","user":"u","password":"p"}}`)
	}))
	defer server.Close()
	e := &engine{client: newCloudClient(), boot: bootstrap{Origin: server.URL}, healthDir: t.TempDir(), jobs: make(chan job, 1), sip: sipConfig{Domain: "registrar", User: "u", Password: "p"}}
	e.registered.Store(true)
	e.sync(context.Background())
	if !e.registered.Load() || e.getSIP().Password != "p" || e.jobPending.Load() {
		t.Fatal("cloud outage cleared SIP or latched job reservation")
	}
	e.cloudPolicy.attempted = time.Now().Add(-6 * time.Second)
	e.cloudPolicy.next = time.Now().Add(2 * time.Minute)
	e.cloudRecovered.Store(true)
	e.sync(context.Background())
	if requests.Load() != 2 || e.cloudPolicy.failures != 0 {
		t.Fatal("recovered network remained in old backoff")
	}
}

func TestCloudRequestTimeoutDoesNotLatchClient(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		if requests.Add(1) == 1 {
			<-r.Context().Done()
			return
		}
		fmt.Fprint(w, `{}`)
	}))
	defer server.Close()
	e := &engine{client: newCloudClient(), boot: bootstrap{Origin: server.URL}}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if err := e.api(ctx, "/edge/sync", nil, &syncReply{}); err == nil {
		t.Fatal("stalled response must time out")
	}
	if err := e.api(context.Background(), "/edge/sync", nil, &syncReply{}); err != nil {
		t.Fatal("next request did not recover:", err)
	}
}

func TestNetworkChangeClosesOldPushAndSchedulesFreshSIPAndCloud(t *testing.T) {
	client, peer := net.Pipe()
	defer peer.Close()
	e := &engine{client: newCloudClient(), wakeConn: client, wakeCh: make(chan struct{}, 1), registrationWake: make(chan struct{}, 1), pushReconnect: make(chan struct{}, 1)}
	e.registered.Store(true)
	e.networkChanged()
	peer.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := peer.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("old push socket was not closed: %v", err)
	}
	if len(e.registrationWake) != 1 || len(e.pushReconnect) != 1 || len(e.wakeCh) != 1 || !e.cloudRecovered.Load() {
		t.Fatal("network switch did not schedule all reconnections")
	}
	if e.registered.Load() {
		t.Fatal("new network must confirm its SIP NAT contact")
	}
	// Repeated changes coalesce instead of blocking a network recovery loop.
	e.networkChanged()
}
