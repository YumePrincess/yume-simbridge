package main

import (
	"encoding/binary"
	"math"
	"sync/atomic"
	"time"
)

// waitingRingback is per outbound call. Only the module -> SIP audio goroutine
// renders it; CLCC sets waiting=false as soon as the cellular call is active.
// Once any carrier audio is heard, do not fill its natural pauses with tones.
type waitingRingback struct {
	waiting      atomic.Bool
	started      time.Time
	heardCarrier bool
}

func newWaitingRingback(now time.Time) *waitingRingback {
	r := &waitingRingback{started: now}
	r.waiting.Store(true)
	return r
}

func (r *waitingRingback) fill(pcm []byte, now time.Time) {
	if r == nil || !r.waiting.Load() || r.heardCarrier {
		return
	}
	// Signed little-endian PCM, 8 kHz mono. Reject DC offset when detecting
	// meaningful audio, preserving even quiet announcements rather than mixing.
	count := len(pcm) / 2
	if count == 0 {
		return
	}
	var sum, squares float64
	for i := 0; i < count; i++ {
		value := float64(int16(binary.LittleEndian.Uint16(pcm[i*2:])))
		sum += value
		squares += value * value
	}
	mean := sum / float64(count)
	if squares/float64(count)-mean*mean >= 128*128 {
		r.heardCarrier = true
		return
	}
	elapsed := now.Sub(r.started) - 1500*time.Millisecond
	if elapsed < 0 {
		return
	}
	// Familiar 450 Hz ringback: one second on, four seconds off. Use a short
	// ramp at both edges to avoid clicks. Never send this into the SIM uplink.
	first := int64(elapsed / (time.Second / 8000))
	for i := 0; i < count; i++ {
		sample := first + int64(i)
		phase := sample % 40000
		amplitude := 0.0
		if phase < 8000 {
			envelope := math.Min(1, math.Min(float64(phase)/40, float64(7999-phase)/40))
			amplitude = 3500 * envelope * math.Sin(2*math.Pi*450*float64(sample)/8000)
		}
		binary.LittleEndian.PutUint16(pcm[i*2:], uint16(int16(amplitude)))
	}
}
