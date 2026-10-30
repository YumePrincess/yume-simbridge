package main

import "testing"

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
