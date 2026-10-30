package main

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/emiago/diago"
	"github.com/emiago/sipgo/sip"
)

// A refresh is a new SIP transaction, not a retransmission of the previous
// authenticated REGISTER. Keep Call-ID/Contact/CSeq, replace Via and digest.
func registerSIP(ctx context.Context, tr *diago.RegisterTransaction) error {
	tr.Origin.RemoveHeader("Via")
	tr.Origin.RemoveHeader("Authorization")
	tr.Origin.RemoveHeader("Proxy-Authorization")
	attempt, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	return tr.Register(attempt)
}

func unregisterSIP(tr *diago.RegisterTransaction) error {
	// Delete this Contact only. A wildcard would also remove another device's
	// binding during a handover or any unrelated phone using the same AOR.
	tr.Origin.RemoveHeader("Expires")
	expiry := sip.ExpiresHeader(0)
	tr.Origin.AppendHeader(&expiry)
	if contact := tr.Origin.Contact(); contact != nil {
		contact.Params.Remove("expires")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return registerSIP(ctx, tr)
}

func registrationDelay(err error, failures int) time.Duration {
	if err == nil {
		return 30 * time.Second
	} // Retain UDP/NAT reachability.
	delay := 10 * time.Second
	for n := 1; n < failures && delay < time.Minute; n++ {
		delay *= 2
	}
	if delay > time.Minute {
		delay = time.Minute
	}
	var response *diago.RegisterResponseError
	if errors.As(err, &response) && response.StatusCode() == 403 {
		delay = time.Minute
	}
	return delay
}

func (e *engine) registerLoop(ctx context.Context) {
	var tr *diago.RegisterTransaction
	var config sipConfig
	owned := false
	failures := 0
	cleanup := func() {
		e.registered.Store(false)
		if tr != nil && owned {
			if err := unregisterSIP(tr); err != nil {
				slog.Warn("SIP unregister failed", "error", err)
			} else {
				slog.Info("SIP contact unregistered")
			}
		}
		tr = nil
		owned = false
		failures = 0
	}
	defer cleanup()
	next := time.Now()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		if ctx.Err() != nil {
			return
		}
		current := e.getSIP()
		if current != config {
			cleanup()
			config = current
			next = time.Now()
		}
		if config.Domain != "" && config.User != "" && config.Password != "" && !time.Now().Before(next) {
			var err error
			if tr == nil {
				var uri sip.Uri
				err = sip.ParseUri("sip:"+config.User+"@"+config.Domain, &uri)
				if err == nil {
					tr, err = e.dg.RegisterTransaction(ctx, uri, diago.RegisterOptions{Username: config.User, Password: config.Password, Expiry: 600 * time.Second})
				}
			}
			if err == nil {
				err = registerSIP(ctx, tr)
			}
			if err == nil {
				owned = true
			}
			if ctx.Err() != nil {
				return
			}
			if err != nil {
				e.registered.Store(false)
				failures++
				slog.Warn("SIP registration failed", "error", err, "retry_seconds", registrationDelay(err, failures).Seconds())
			} else {
				if !e.registered.Swap(true) {
					slog.Info("Twilio SIP registered")
				}
				owned = true
				failures = 0
			}
			next = time.Now().Add(registrationDelay(err, failures))
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
