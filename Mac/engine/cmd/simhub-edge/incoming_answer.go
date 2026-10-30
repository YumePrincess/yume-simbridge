package main

import (
	"context"
	"errors"
	"github.com/cellbridge/cellbridge/gateway/internal/modem"
	"time"
)

// Only the authenticated, ticket-bound confirmation can unlock cellular ATA.
// A final SIP response can also be a failure announcement and is insufficient.
func answerAfterConfirmation(ctx context.Context, check func(context.Context) (bool, error), answer func(context.Context) error) error {
	checkCtx, stop := context.WithTimeout(ctx, 5*time.Second)
	accepted, err := check(checkCtx)
	stop()
	if err != nil {
		return err
	}
	if !accepted {
		return errors.New("destination has not accepted this call")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return answer(ctx)
}

func (e *engine) answerIncoming(ctx context.Context, id modem.CallID) error {
	activeCtx, stop := context.WithTimeout(ctx, 15*time.Second)
	defer stop()
	if err := activeCtx.Err(); err != nil {
		return err
	}
	if err := e.modem.Answer(activeCtx, id); err != nil {
		return err
	}
	active, err := e.modem.WaitActiveDir(activeCtx, modem.CLCCDirIncoming)
	if err != nil {
		return err
	}
	if !active {
		return errors.New("SIM incoming call did not become active")
	}
	return nil
}

// Monitor actual CLCC while ringing/private screening. The caller's hangup
// URC also cancels the same parent, but is not our only source of truth.
func watchIncomingRinging(ctx context.Context, cancel context.CancelFunc, check func(context.Context) (bool, error)) func() {
	watchCtx, stop := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			checkCtx, end := context.WithTimeout(watchCtx, 4*time.Second)
			ringing, err := check(checkCtx)
			end()
			if watchCtx.Err() != nil {
				return
			}
			if err != nil || !ringing {
				cancel()
				return
			}
			select {
			case <-watchCtx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	return func() { stop(); <-done }
}

func watchConnectedCall(ctx context.Context, cancel context.CancelFunc, check func(context.Context) (bool, error)) func() {
	watchCtx, stop := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		failures := 0
		for {
			select {
			case <-watchCtx.Done():
				return
			case <-ticker.C:
			}
			probe, end := context.WithTimeout(watchCtx, time.Second)
			present, err := check(probe)
			end()
			if watchCtx.Err() != nil {
				return
			}
			if err != nil {
				failures++
				if failures < 3 {
					continue
				}
			} else {
				failures = 0
				if present {
					continue
				}
			}
			cancel()
			return
		}
	}()
	return func() { stop(); <-done }
}
