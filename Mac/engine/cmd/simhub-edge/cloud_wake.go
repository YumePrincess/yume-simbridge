package main

import (
	"bufio"
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

func (e *engine) signalCloudWake() {
	e.cloudWake.Store(true)
	e.jobWake.Store(true)
	select {
	case e.wakeCh <- struct{}{}:
	default:
	}
}
func (e *engine) cloudWakeLoop(ctx context.Context) {
	delay := 5 * time.Second
	for ctx.Err() == nil {
		dialer := ws.Dialer{Timeout: 15 * time.Second, Header: ws.HandshakeHeaderHTTP(http.Header{
			"Authorization": []string{"Bearer " + e.boot.Token}, "User-Agent": []string{"YumeSimHub/" + Version},
		})}
		conn, buffer, _, err := dialer.Dial(ctx, strings.Replace(e.boot.Origin, "https://", "wss://", 1)+"/edge/wake")
		if err == nil {
			delay = 5 * time.Second
			e.wakeConnected.Store(true)
			e.signalCloudWake()
			slog.Info("cloud push connected")
			err = e.readCloudWake(ctx, conn, buffer)
			e.wakeConnected.Store(false)
			conn.Close()
		}
		if ctx.Err() != nil {
			return
		}
		slog.Warn("cloud push reconnect pending")
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}
		if delay < 120*time.Second {
			delay *= 2
			if delay > 120*time.Second {
				delay = 120 * time.Second
			}
		}
	}
}
func (e *engine) readCloudWake(ctx context.Context, conn net.Conn, buffer *bufio.Reader) error {
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	life, end := context.WithCancel(ctx)
	defer end()
	var writeMu sync.Mutex
	write := func(op ws.OpCode, data []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		return wsutil.WriteClientMessage(conn, op, data)
	}
	go func() {
		ticker := time.NewTicker(45 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-life.Done():
				return
			case <-ticker.C:
				if write(ws.OpText, []byte("ping")) != nil {
					conn.Close()
					return
				}
			}
		}
	}()
	var source io.Reader = conn
	if buffer != nil {
		source = buffer
	}
	reader := wsutil.Reader{Source: source, State: ws.StateClientSide, MaxFrameSize: 1024, CheckUTF8: true}
	for {
		conn.SetReadDeadline(time.Now().Add(100 * time.Second))
		header, err := reader.NextFrame()
		if err != nil {
			return err
		}
		if !header.Fin {
			return errors.New("unexpected fragmented wake")
		}
		payload, err := io.ReadAll(io.LimitReader(&reader, 1025))
		if err != nil {
			return err
		}
		if len(payload) > 1024 {
			return errors.New("wake too large")
		}
		switch header.OpCode {
		case ws.OpText:
			if string(payload) == "wake" {
				e.signalCloudWake()
			} else if string(payload) != "pong" {
				return errors.New("unexpected wake message")
			}
		case ws.OpPing:
			if err := write(ws.OpPong, payload); err != nil {
				return err
			}
		case ws.OpClose:
			return io.EOF
		}
	}
}
