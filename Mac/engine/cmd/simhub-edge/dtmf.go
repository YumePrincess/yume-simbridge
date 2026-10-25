package main

import (
	"context"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/cellbridge/cellbridge/gateway/internal/modem"
)

type toneSender interface {
	SendDTMF(context.Context, modem.CallID, rune) error
}
type toneRelay struct {
	ctx    context.Context
	cancel context.CancelFunc
	queue  chan rune
	done   sync.WaitGroup
}

func newToneRelay(parent context.Context, sender toneSender, id modem.CallID) *toneRelay {
	ctx, cancel := context.WithCancel(parent)
	r := &toneRelay{ctx: ctx, cancel: cancel, queue: make(chan rune, 128)}
	r.done.Add(1)
	go func() {
		defer r.done.Done()
		for {
			select {
			case <-ctx.Done():
				return
			case digit := <-r.queue:
				c, stop := context.WithTimeout(ctx, 3*time.Second)
				err := sender.SendDTMF(c, id, digit)
				stop()
				if err != nil && ctx.Err() == nil {
					slog.Warn("DTMF forwarding failed")
				}
			}
		}
	}()
	return r
}

// Media parsing never waits for a serial AT exchange. Numbers are deliberately
// never written to logs: callers may be entering account numbers or PINs.
func (r *toneRelay) enqueue(digit rune) error {
	if !strings.ContainsRune("0123456789*#ABCD", digit) {
		return nil
	}
	select {
	case <-r.ctx.Done():
		return nil
	case r.queue <- digit:
		return nil
	default:
		slog.Warn("DTMF queue full")
		return nil
	}
}
func (r *toneRelay) close() { r.cancel(); r.done.Wait() }
