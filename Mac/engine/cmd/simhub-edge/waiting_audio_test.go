package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestWaitingAudioIntroThenMusicLoopsWithoutReplayingIntro(t *testing.T) {
	player := waitingPlayer{intro: []byte{1, 2, 3, 4}, music: []byte{5, 6, 7, 8}}
	out := make([]byte, 10)
	if !player.fill(out) {
		t.Fatal("intro completion not signaled")
	}
	if !bytes.Equal(out, []byte{1, 2, 3, 4, 5, 6, 7, 8, 5, 6}) {
		t.Fatal("intro/music order incorrect")
	}
	player.fill(out)
	if !bytes.Equal(out, []byte{7, 8, 5, 6, 7, 8, 5, 6, 7, 8}) {
		t.Fatal("music did not loop independently")
	}
	if len(forwardIntro) < 16000 || len(forwardMusic) < 16000 || len(forwardMusic)%2 != 0 {
		t.Fatal("missing bundled telephone audio")
	}
	max := 0
	for i := 0; i < len(forwardMusic); i += 2 {
		v := int(int16(binary.LittleEndian.Uint16(forwardMusic[i:])))
		if v < 0 {
			v = -v
		}
		if v > max {
			max = v
		}
	}
	if max == 0 || max > 10000 {
		t.Fatalf("music is silent or exceeds intended level: %d", max)
	}
}

func TestWaitingMusicUsesOnlySIMDownlinkAndStopsOnCancellation(t *testing.T) {
	dir := t.TempDir()
	e := &engine{rxPath: filepath.Join(dir, "rx"), txPath: filepath.Join(dir, "tx"), healthDir: dir}
	for _, p := range []string{e.rxPath, e.txPath} {
		if err := syscall.Mkfifo(p, 0600); err != nil {
			t.Fatal(err)
		}
	}
	rx, err := os.OpenFile(e.rxPath, os.O_RDWR|syscall.O_NONBLOCK, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer rx.Close()
	tx, err := os.OpenFile(e.txPath, os.O_RDWR|syscall.O_NONBLOCK, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	healthDone := make(chan struct{})
	go func() {
		defer close(healthDone)
		ticker := time.NewTicker(25 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				writeHealth(filepath.Join(dir, "audio-health.json"), map[string]any{"updated": time.Now().UnixMilli(), "ready": true, "unitsRunning": true})
			}
		}
	}()
	defer func() { cancel(); <-healthDone }()
	caller := bytes.Repeat([]byte{0x33, 0x66}, 160)
	_, _ = rx.Write(caller)
	intro := bytes.Repeat([]byte{0x00, 0x20}, 320)
	music := bytes.Repeat([]byte{0x22, 0x11}, 160)
	announced := make(chan struct{})
	done := make(chan error, 1)
	go func() { done <- e.waitingAudioWithPlayer(ctx, announced, waitingPlayer{intro: intro, music: music}) }()
	var output []byte
	buffer := make([]byte, 4096)
	for len(output) < 12800 {
		n, err := syscall.Read(int(tx.Fd()), buffer)
		if err != nil && !errors.Is(err, syscall.EAGAIN) {
			t.Fatal(err)
		}
		if n > 0 {
			output = append(output, buffer[:n]...)
		}
		if bytes.Contains(output, music) {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("waiting audio stopped early: %v", err)
		case <-time.After(10 * time.Millisecond):
		}
	}
	select {
	case <-announced:
	default:
		t.Fatal("full announcement was not completed")
	}
	if bytes.Index(output, intro) < 0 || bytes.Index(output, music) < bytes.Index(output, intro) {
		t.Fatal("announcement must precede music")
	}
	if bytes.Contains(output, caller) {
		t.Fatal("caller capture leaked into waiting audio")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("unexpected stop: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("music did not stop promptly")
	}
}
