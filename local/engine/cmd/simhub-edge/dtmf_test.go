package main

import (
	"context"
	"errors"
	"github.com/cellbridge/cellbridge/gateway/internal/modem"
	"testing"
	"time"
)

type fakeTones struct {
	received chan rune
	calls    chan modem.CallID
}

func (f *fakeTones) SendDTMF(ctx context.Context, id modem.CallID, d rune) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case f.received <- d:
		f.calls <- id
	}
	if d == '2' {
		return errors.New("temporary AT error")
	}
	return nil
}
func TestToneRelayPreservesOrderAndCallIdentityAfterAnATError(t *testing.T) {
	f := &fakeTones{make(chan rune, 16), make(chan modem.CallID, 16)}
	r := newToneRelay(context.Background(), f, "active-call")
	defer r.close()
	digits := "1234567890*#"
	for _, d := range digits {
		if err := r.enqueue(d); err != nil {
			t.Fatal(err)
		}
	}
	for _, want := range digits {
		select {
		case got := <-f.received:
			if got != want {
				t.Fatalf("out-of-order tone: got %q want %q", got, want)
			}
			if id := <-f.calls; id != "active-call" {
				t.Fatal("tone sent to another call")
			}
		case <-time.After(time.Second):
			t.Fatal("tone not forwarded")
		}
	}
}
func TestToneRelayRejectsNonDTMFAndStopsWithCall(t *testing.T) {
	f := &fakeTones{make(chan rune, 16), make(chan modem.CallID, 16)}
	ctx, cancel := context.WithCancel(context.Background())
	r := newToneRelay(ctx, f, "call")
	_ = r.enqueue('X')
	cancel()
	r.close()
	_ = r.enqueue('9')
	select {
	case <-f.received:
		t.Fatal("tone forwarded outside the active call")
	default:
	}
}
