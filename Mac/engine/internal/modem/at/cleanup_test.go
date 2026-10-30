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
