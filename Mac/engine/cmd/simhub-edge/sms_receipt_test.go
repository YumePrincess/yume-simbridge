package main

import "testing"
import "github.com/cellbridge/cellbridge/gateway/internal/sms"

func TestReceiptStableAcrossDevicesAndMultipartOrder(t *testing.T) {
	a := smsReceiptFingerprint([]string{"pdu-one", "pdu-two"})
	b := smsReceiptFingerprint([]string{"pdu-two", "pdu-one"})
	if a != b {
		t.Fatal("arrival order changed receipt")
	}
	if a == smsReceiptFingerprint([]string{"pdu-one", "a-new-PDU-with-new-service-timestamp"}) {
		t.Fatal("distinct SMS suppressed")
	}
}

func TestSentCleanupRequiresTheSameDestinationBodyAndMultipartIdentity(t *testing.T) {
	original := sms.DecodedMessage{Submitted: true, Sender: "10086", Body: "hello", ConcatRef: 2, PartNo: 1, TotalParts: 2}
	if !sameSubmittedSMS(original, original) {
		t.Fatal("identical submitted SMS must match")
	}
	changed := original
	changed.PartNo = 2
	if sameSubmittedSMS(original, changed) {
		t.Fatal("another multipart segment matched")
	}
	changed = original
	changed.Sender = "10010"
	if sameSubmittedSMS(original, changed) {
		t.Fatal("another recipient matched")
	}
	changed = original
	changed.Submitted = false
	if sameSubmittedSMS(original, changed) {
		t.Fatal("incoming SMS matched an outbox entry")
	}
}
