package at

import (
	"context"
	"encoding/hex"
	"strings"
	"testing"
)

func TestSMSCleanupRequiresUnchangedPDU(t *testing.T) {
	for _, match := range []bool{true, false} {
		expected, _ := hex.DecodeString("00010203")
		response := "00010203"
		if !match {
			response = "00010204"
		}
		port := &scriptedPort{responses: map[string]string{"AT+CMGR=2": "\r\n+CMGR: 0,,4\r\n" + response + "\r\nOK\r\n"}}
		a := NewAdapter(NewClient(port))
		err := a.DeleteSMSIfMatches(context.Background(), 2, expected)
		deleted := strings.Contains(strings.Join(port.writes, "\n"), "AT+CMGD=2")
		if deleted != match || (err == nil) != match {
			t.Fatalf("match=%v deleted=%v err=%v", match, deleted, err)
		}
	}
}
func TestCallHistoryCleanupRejectsChangedOrSIMPhonebookSlots(t *testing.T) {
	record := ModuleCallRecord{Storage: "RC", Index: 1, Raw: `+CPBR: 1,"95555",129,""`}
	for _, match := range []bool{true, false} {
		raw := record.Raw
		if !match {
			raw = `+CPBR: 1,"10086",129,""`
		}
		port := &scriptedPort{responses: map[string]string{"AT+CPBR=1": "\r\n" + raw + "\r\nOK\r\n"}}
		a := NewAdapter(NewClient(port))
		err := a.DeleteCallHistoryIfMatches(context.Background(), record)
		deleted := strings.Contains(strings.Join(port.writes, "\n"), "AT+CPBW=1")
		if deleted != match || (err == nil) != match {
			t.Fatalf("match=%v deleted=%v err=%v", match, deleted, err)
		}
		record.Storage = "SM"
		if a.DeleteCallHistoryIfMatches(context.Background(), record) == nil {
			t.Fatal("SIM contacts must never be deleted")
		}
		record.Storage = "RC"
	}
}
