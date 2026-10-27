package main

import "time"

const cloudHeartbeat = 30 * time.Second

type cloudSyncState struct {
	Connected, Voice, SIP, Busy bool
	SIM, Registration           string
}

// Local health is still sampled every five seconds. Only important transitions
// and queued local work bypass the idle cloud heartbeat; RSSI noise does not.
type syncPolicy struct {
	last      cloudSyncState
	attempted time.Time
	next      time.Time
	failures  int
}

func (p *syncPolicy) due(now time.Time, state cloudSyncState, wake bool) bool {
	if p.attempted.IsZero() {
		return true
	}
	if now.Sub(p.attempted) < 5*time.Second {
		return false
	}
	if p.failures > 0 {
		return !now.Before(p.next)
	}
	return wake || state != p.last || !now.Before(p.next)
}
func (p *syncPolicy) complete(now time.Time, state cloudSyncState, success, more bool) {
	p.attempted = now
	p.last = state
	delay := cloudHeartbeat
	if success {
		p.failures = 0
		if more {
			delay = 5 * time.Second
		}
	} else {
		p.failures++
		delay = 5 * time.Second
		for i := 1; i < p.failures && delay < 120*time.Second; i++ {
			delay *= 2
		}
		if delay > 120*time.Second {
			delay = 120 * time.Second
		}
	}
	p.next = now.Add(delay)
}
