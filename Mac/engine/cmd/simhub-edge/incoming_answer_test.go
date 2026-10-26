package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestAnswerRequiresConfirmedTicketAndLiveContext(t *testing.T) {
	for _, test := range []struct {
		name     string
		accepted bool
		err      error
		cancel   bool
		want     int
	}{
		{"confirmed", true, nil, false, 1},
		{"network answer only", false, nil, false, 0},
		{"cloud unavailable", true, errors.New("offline"), false, 0},
		{"caller hung up during check", true, nil, true, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			calls := 0
			err := answerAfterConfirmation(ctx, func(context.Context) (bool, error) {
				if test.cancel {
					cancel()
				}
				return test.accepted, test.err
			}, func(context.Context) error { calls++; return nil })
			if calls != test.want || (err == nil) != (test.want == 1) {
				t.Fatalf("answer calls=%d error=%v", calls, err)
			}
		})
	}
}
func TestRingingWatchCancelsOnDisappearanceOrReadFailure(t *testing.T) {
	for _, readErr := range []error{nil, errors.New("USB disconnected")} {
		ctx, cancel := context.WithCancel(context.Background())
		stop := watchIncomingRinging(ctx, cancel, func(context.Context) (bool, error) { return false, readErr })
		select {
		case <-ctx.Done():
		case <-time.After(time.Second):
			t.Fatal("lost ring did not cancel dial")
		}
		stop()
	}
}
func TestRingingWatchCanStopBeforeAnswerWithoutCancellingCall(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	checked := make(chan struct{}, 1)
	stop := watchIncomingRinging(ctx, cancel, func(context.Context) (bool, error) { checked <- struct{}{}; return true, nil })
	<-checked
	stop()
	if ctx.Err() != nil {
		t.Fatal("stopping monitor cancelled accepted call")
	}
}
