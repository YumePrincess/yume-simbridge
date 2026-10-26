package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// User-supplied music is converted once at build time, embedded in the signed
// executable, and never fetched from Downloads or an external player at runtime.
//
//go:embed assets/forward-intro.s16le
var forwardIntro []byte

//go:embed assets/forward-bgm.s16le
var forwardMusic []byte

type waitingPlayer struct {
	intro, music       []byte
	introPos, musicPos int
}

func (p *waitingPlayer) fill(out []byte) bool {
	position := 0
	for position < len(out) {
		if p.introPos < len(p.intro) {
			n := copy(out[position:], p.intro[p.introPos:])
			p.introPos += n
			position += n
		} else {
			n := copy(out[position:], p.music[p.musicPos:])
			p.musicPos = (p.musicPos + n) % len(p.music)
			position += n
		}
	}
	return p.introPos == len(p.intro)
}
func audioRunning(path string, started time.Time, now time.Time) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var health struct {
		Updated int64 `json:"updated"`
		Ready   bool  `json:"ready"`
		Running bool  `json:"unitsRunning"`
	}
	if json.Unmarshal(data, &health) != nil {
		return false
	}
	return health.Ready && health.Running && health.Updated >= started.UnixMilli() && now.UnixMilli()-health.Updated >= 0 && now.UnixMilli()-health.Updated < 4000
}

// SIM downlink only. Destination audio stays in Twilio's private Number screen.
// Discard SIM capture here so CoreAudio stays awake without leaking caller audio.
func (e *engine) waitingAudio(ctx context.Context, introDone chan<- struct{}) error {
	return e.waitingAudioWithPlayer(ctx, introDone, waitingPlayer{intro: forwardIntro, music: forwardMusic})
}
func (e *engine) waitingAudioWithPlayer(ctx context.Context, introDone chan<- struct{}, player waitingPlayer) error {
	rx, err := os.OpenFile(e.rxPath, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	defer rx.Close()
	tx, err := os.OpenFile(e.txPath, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	defer tx.Close()
	if len(player.intro)%2 != 0 || len(player.music) == 0 || len(player.music)%2 != 0 {
		return errors.New("invalid waiting audio assets")
	}
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	buffer := make([]byte, 320)
	discard := make([]byte, 4096)
	started := time.Now()
	running := false
	announced := false
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case instant := <-ticker.C:
			_, err = syscall.Read(int(rx.Fd()), discard)
			if err != nil && !errors.Is(err, syscall.EAGAIN) {
				return err
			}
			next := player
			finished := false
			clear(buffer)
			if !running {
				running = instant.Sub(started) >= 500*time.Millisecond && audioRunning(filepath.Join(e.healthDir, "audio-health.json"), started, instant)
				if instant.Sub(started) > 3*time.Second && !running {
					return errors.New("audio capture did not wake for waiting announcement")
				}
			}
			if running {
				finished = next.fill(buffer)
			}
			n, err := tx.Write(buffer)
			if errors.Is(err, syscall.EAGAIN) {
				continue
			}
			if err != nil {
				return err
			}
			if n != len(buffer) {
				return io.ErrShortWrite
			}
			player = next
			if finished && !announced {
				close(introDone)
				announced = true
			}
		}
	}
}
