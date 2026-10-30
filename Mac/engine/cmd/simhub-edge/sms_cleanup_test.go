package main

import (
	"context"
	"encoding/hex"
	"github.com/cellbridge/cellbridge/gateway/internal/db"
	"github.com/cellbridge/cellbridge/gateway/internal/modem"
	"github.com/cellbridge/cellbridge/gateway/internal/sms"
	"path/filepath"
	"testing"
)

func TestOutboxCleanupRequiresConfirmedCloudJob(t *testing.T) {
	database, err := db.Open(filepath.Join(t.TempDir(), "test.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	if err = database.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	_, err = database.Exec(`CREATE TABLE edge_jobs(id TEXT PRIMARY KEY,status TEXT,acked INTEGER);CREATE TABLE edge_sms_owned(job_id TEXT,message_id TEXT);`)
	if err != nil {
		t.Fatal(err)
	}
	parts, _ := sms.EncodeSubmitSegments("10086", "hello", 3)
	database.Exec("INSERT INTO sms_outbound_parts(message_id,pdu) VALUES('message',?)", parts[0].PDU)
	database.Exec("INSERT INTO edge_sms_owned(job_id,message_id) VALUES('job','message')")
	database.Exec("INSERT INTO edge_jobs(id,status,acked) VALUES('job','sent',0)")
	raw, _ := hex.DecodeString(parts[0].PDU)
	candidate := modem.RawSMS{RawPDU: raw, StorageStatus: 3}
	e := &engine{database: database}
	if e.ownedSentPDU(ctx, candidate) {
		t.Fatal("unacknowledged send was eligible for deletion")
	}
	database.Exec("UPDATE edge_jobs SET acked=1")
	if !e.ownedSentPDU(ctx, candidate) {
		t.Fatal("confirmed sent record did not match")
	}
	candidate.StorageStatus = 2
	if e.ownedSentPDU(ctx, candidate) {
		t.Fatal("unsent draft was eligible for deletion")
	}
	candidate.StorageStatus = 3
	database.Exec("UPDATE edge_jobs SET status='unknown'")
	if e.ownedSentPDU(ctx, candidate) {
		t.Fatal("unknown outcome was eligible for deletion")
	}
}
