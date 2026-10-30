package at

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestCallURCsArriveBeforeSlowCommandCompletes(t *testing.T) {
	clientPort, module := net.Pipe()
	defer clientPort.Close()
	defer module.Close()
	client := NewClient(clientPort)
	events := make(chan string, 4)
	client.SetLineHandler(func(line string) { events <- line })
	release := make(chan struct{})
	defer close(release)
	go func() {
		buf := make([]byte, 64)
		module.Read(buf)
		module.Write([]byte("RING\r\n+CLIP: \"10086\",129\r\nNO CARRIER\r\n"))
		<-release
		module.Write([]byte("OK\r\n"))
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := client.Exchange(ctx, "AT+CMGL=4"); done <- err }()
	for n := 0; n < 3; n++ {
		select {
		case <-events:
		case <-time.After(200 * time.Millisecond):
			t.Fatal("call notification waited for command response")
		}
	}
	select {
	case <-done:
		t.Fatal("fixture command should still be pending")
	default:
	}
}
func TestTrailingCallURCsInFinalResponseAreNotLost(t *testing.T) {
	port := &scriptedPort{responses: map[string]string{"AT": "OK\r\nRING\r\nNO CARRIER\r\n"}}
	client := NewClient(port)
	var events []string
	client.SetLineHandler(func(line string) { events = append(events, line) })
	if _, err := client.Exchange(context.Background(), "AT"); err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 {
		t.Fatalf("trailing URCs lost: %v", events)
	}
}

func TestDialFailureIsFinalWithoutWaitingForOK(t *testing.T) {
	port := &scriptedPort{responses: map[string]string{"ATD10086;": "NO CARRIER\r\n"}}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := NewClient(port).Exchange(ctx, "ATD10086;"); err == nil {
		t.Fatal("failed dial was accepted")
	}
	if ctx.Err() != nil {
		t.Fatal("failed dial waited for missing OK")
	}
}
func TestHangupPrefersCHUPWithATHFallback(t *testing.T) {
	for _, fallback := range []bool{false, true} {
		responses := map[string]string{}
		if fallback {
			responses["AT+CHUP"] = "ERROR\r\n"
		}
		port := &scriptedPort{responses: responses}
		adapter := NewAdapter(NewClient(port))
		adapter.active = "call"
		if err := adapter.Hangup(context.Background(), "call"); err != nil {
			t.Fatal(err)
		}
		if len(port.writes) == 0 || port.writes[0] != "AT+CHUP\r" {
			t.Fatal("did not release voice explicitly")
		}
		if fallback && (len(port.writes) < 2 || port.writes[1] != "ATH\r") {
			t.Fatal("missing legacy fallback")
		}
	}
}
