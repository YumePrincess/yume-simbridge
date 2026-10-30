package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"strings"
)

// Hash all original PDUs, independent of device-local IDs and arrival order.
func smsReceiptFingerprint(parts []string) string {
	parts = append([]string(nil), parts...)
	sort.Strings(parts)
	hash := sha256.Sum256([]byte(strings.Join(parts, "\n")))
	return hex.EncodeToString(hash[:])
}
func (e *engine) smsDelivered(ctx context.Context, pdu []byte) bool {
	hash := sha256.Sum256(pdu)
	var count int
	err := e.database.QueryRowContext(ctx, "SELECT count(*) FROM sms_segments s JOIN cloud_delivered d ON d.id=s.message_id WHERE s.pdu_hash=?", hex.EncodeToString(hash[:])).Scan(&count)
	return err == nil && count > 0
}
