package main

import (
	"bufio"
	"context"
	"github.com/cellbridge/cellbridge/gateway/internal/modem/at"
	"net"
	"testing"
	"time"
)

type delayedHangup struct{ started, release chan struct{} }

func (d delayedHangup) Hangup(context.Context) error { close(d.started); <-d.release; return nil }
func TestCellularHangupDoesNotWaitForSlowSIP(t *testing.T) {
	host, module := net.Pipe()
	defer host.Close()
	defer module.Close()
	commands := make(chan string, 4)
	go func() {
		reader := bufio.NewReader(module)
		for {
			line, err := reader.ReadString('\r')
			if err != nil {
				return
			}
			commands <- line
			module.Write([]byte("OK\r\n"))
		}
	}()
	adapter := at.NewAdapter(at.NewClient(host))
	defer adapter.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	id, err := adapter.Dial(ctx, "10086")
	if err != nil {
		t.Fatal(err)
	}
	<-commands
	e := &engine{modem: adapter, wakeCh: make(chan struct{}, 1)}
	e.setCall(id, nil)
	e.busy.Store(true)
	remote := delayedHangup{make(chan struct{}), make(chan struct{})}
	done := make(chan struct{})
	go func() { defer close(done); e.finishCall(id, remote) }()
	defer func() { close(remote.release); <-done }()
	select {
	case cmd := <-commands:
		if cmd != "AT+CHUP\r" {
			t.Fatalf("wrong release: %s", cmd)
		}
	case <-time.After(200 * time.Millisecond):
		t.Fatal("cellular leg waited for SIP")
	}
	deadline := time.Now().Add(200 * time.Millisecond)
	for e.callActive() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if e.callActive() {
		t.Fatal("live call status waited for remote teardown")
	}
	select {
	case <-done:
		t.Fatal("remote fixture should still be waiting")
	default:
	}
}
