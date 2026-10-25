package main

import (
	"bytes"
	"encoding/binary"
	"math"
	"testing"
	"time"
)

func TestRingbackOnlyDuringSilentUnansweredWait(t *testing.T) {
	start := time.Now()
	r := newWaitingRingback(start)
	frame := make([]byte, 320)
	r.fill(frame, start.Add(time.Second))
	if !bytes.Equal(frame, make([]byte, 320)) {
		t.Fatal("tone before silence grace period")
	}
	r.fill(frame, start.Add(1500*time.Millisecond))
	if bytes.Equal(frame, make([]byte, 320)) {
		t.Fatal("missing ringback during silent wait")
	}
	// The ringback has four silent seconds after the one-second burst.
	clear(frame)
	r.fill(frame, start.Add(3*time.Second))
	if !bytes.Equal(frame, make([]byte, 320)) {
		t.Fatal("ringback must have a quiet interval")
	}
	r.fill(frame, start.Add(6500*time.Millisecond))
	if bytes.Equal(frame, make([]byte, 320)) {
		t.Fatal("ringback must repeat")
	}
	r.waiting.Store(false)
	clear(frame)
	r.fill(frame, start.Add(6500*time.Millisecond))
	if !bytes.Equal(frame, make([]byte, 320)) {
		t.Fatal("tone continued after answer/failure")
	}
}

func TestCarrierAudioAndItsPausesRemainUnmodified(t *testing.T) {
	start := time.Now()
	for _, duration := range []time.Duration{time.Second, 2 * time.Second} {
		r := newWaitingRingback(start)
		frame := make([]byte, 320)
		// A quiet carrier announcement, above the -48 dBFS energy threshold.
		for i := 0; i < 160; i++ {
			binary.LittleEndian.PutUint16(frame[i*2:], uint16(int16(400*math.Sin(float64(i)*0.3))))
		}
		original := bytes.Clone(frame)
		r.fill(frame, start.Add(duration))
		if !bytes.Equal(frame, original) {
			t.Fatal("carrier announcement changed")
		}
		for _, delay := range []time.Duration{2 * time.Second, 7 * time.Second, 12 * time.Second} {
			clear(frame)
			r.fill(frame, start.Add(delay))
			if !bytes.Equal(frame, make([]byte, 320)) {
				t.Fatal("tone inserted into carrier audio pause")
			}
		}
	}
}

func TestRingbackToleratesDCAndDoesNotLeakBetweenCalls(t *testing.T) {
	start := time.Now()
	r := newWaitingRingback(start)
	frame := make([]byte, 320)
	for i := 0; i < 160; i++ {
		binary.LittleEndian.PutUint16(frame[i*2:], 500)
	}
	r.fill(frame, start.Add(1500*time.Millisecond))
	if binary.LittleEndian.Uint16(frame[80:]) == 500 {
		t.Fatal("DC offset mistaken for carrier audio")
	}
	var disabled *waitingRingback
	original := bytes.Clone(frame)
	disabled.fill(frame, start.Add(2*time.Second))
	if !bytes.Equal(frame, original) {
		t.Fatal("incoming/answered audio changed")
	}
	// A new call gets its own detector, regardless of the previous call state.
	r.heardCarrier = true
	next := newWaitingRingback(start)
	clear(frame)
	next.fill(frame, start.Add(1500*time.Millisecond))
	if bytes.Equal(frame, make([]byte, 320)) {
		t.Fatal("previous call suppressed the next call's tone")
	}
}
