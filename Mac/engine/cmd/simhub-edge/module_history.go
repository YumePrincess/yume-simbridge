package main

import (
	"context"
	"github.com/cellbridge/cellbridge/gateway/internal/modem/at"
	"log/slog"
	"time"
)

// Reserve the modem briefly while archiving. Never clean while a call is active.
func (e *engine) cleanModuleHistory(ctx context.Context) {
	if !e.busy.CompareAndSwap(false, true) {
		return
	}
	defer e.busy.Store(false)
	c, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	records, err := e.modem.ModuleCallHistory(c)
	if err != nil || len(records) == 0 {
		return
	}
	if len(records) > 6 {
		records = records[:6]
	}
	var reply struct {
		Stored bool `json:"stored"`
	}
	if e.api(c, "/edge/module-history", map[string][]at.ModuleCallRecord{"entries": records}, &reply) != nil || !reply.Stored {
		return
	}
	for _, record := range records {
		if e.modem.DeleteCallHistoryIfMatches(c, record) != nil {
			slog.Warn("Module call history cleanup deferred")
			return
		}
	}
}
