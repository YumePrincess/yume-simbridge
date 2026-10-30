package main

import (
	"context"
	"log/slog"
	"time"
)

// Durable ordered reports. A slow cloud/Twilio request must never postpone
// local ATH, SIP BYE/CANCEL, media startup, or the live health file.
func (e *engine) callEvent(id, status string) {
	if _, err := e.database.Exec("INSERT INTO edge_call_events(id,status) VALUES(?,?)", id, status); err != nil {
		slog.Error("call event persistence failed")
		return
	}
	select {
	case e.callEventWake <- struct{}{}:
	default:
	}
}
func (e *engine) callEventLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		for ctx.Err() == nil {
			var seq int64
			var id, status string
			if err := e.database.QueryRowContext(ctx, "SELECT seq,id,status FROM edge_call_events ORDER BY seq LIMIT 1").Scan(&seq, &id, &status); err != nil {
				break
			}
			attempt, cancel := context.WithTimeout(ctx, 4*time.Second)
			err := e.api(attempt, "/edge/call-event", map[string]string{"id": id, "status": status}, nil)
			cancel()
			if err != nil {
				break
			}
			_, _ = e.database.ExecContext(ctx, "DELETE FROM edge_call_events WHERE seq=?", seq)
		}
		select {
		case <-ctx.Done():
			return
		case <-e.callEventWake:
		case <-ticker.C:
		}
	}
}
