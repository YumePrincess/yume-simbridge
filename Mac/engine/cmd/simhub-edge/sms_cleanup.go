package main

import (
	"context"
	"encoding/hex"
	"github.com/cellbridge/cellbridge/gateway/internal/modem"
	"github.com/cellbridge/cellbridge/gateway/internal/sms"
	"time"
)

func (e *engine) ownedSentPDU(ctx context.Context, raw modem.RawSMS) bool {
	if raw.StorageStatus != 3 {
		return false
	}
	decoded, err := sms.DecodePDU(hex.EncodeToString(raw.RawPDU))
	if err != nil || !decoded.Submitted {
		return false
	}
	rows, err := e.database.QueryContext(ctx, "SELECT p.pdu FROM sms_outbound_parts p JOIN edge_sms_owned o ON o.message_id=p.message_id JOIN edge_jobs j ON j.id=o.job_id WHERE j.status='sent' AND j.acked=1")
	if err != nil {
		return false
	}
	defer rows.Close()
	for rows.Next() {
		var pdu string
		if rows.Scan(&pdu) != nil {
			continue
		}
		expected, err := sms.DecodePDU(pdu)
		if err == nil && sameSubmittedSMS(decoded, expected) {
			return true
		}
	}
	return false
}
func sameSubmittedSMS(a, b sms.DecodedMessage) bool {
	return a.Submitted && b.Submitted && a.Sender == b.Sender && a.Body == b.Body && a.ConcatRef == b.ConcatRef && a.PartNo == b.PartNo && a.TotalParts == b.TotalParts
}
func (e *engine) cleanupStoredSMS(ctx context.Context) {
	if e.busy.Load() {
		return
	}
	c, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	raws, _, err := e.modem.ListSMS(c, "")
	if err != nil {
		return
	}
	for _, raw := range raws {
		if e.smsDelivered(c, raw.RawPDU) || e.ownedSentPDU(c, raw) {
			_ = e.modem.DeleteSMSIfMatches(c, raw.ModemIndex, raw.RawPDU)
		}
	}
}
