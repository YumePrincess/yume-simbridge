package at

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
)

// Never delete by a remembered slot alone: it might now hold a different SMS.
func (a *Adapter) DeleteSMSIfMatches(ctx context.Context, index int, expected []byte) error {
	if index < 0 || len(expected) == 0 {
		return errors.New("invalid SMS cleanup identity")
	}
	if _, err := a.client.Exchange(ctx, `AT+CPMS="MT"`); err != nil {
		return err
	}
	if _, err := a.client.Exchange(ctx, "AT+CMGF=0"); err != nil {
		return err
	}
	lines, err := a.client.Exchange(ctx, fmt.Sprintf("AT+CMGR=%d", index))
	if err != nil {
		return err
	}
	matched := false
	for _, line := range lines {
		pdu, e := hex.DecodeString(strings.TrimSpace(line))
		if e == nil && bytes.Equal(pdu, expected) {
			matched = true
		}
	}
	if !matched {
		return errors.New("SMS slot changed; cleanup skipped")
	}
	_, err = a.client.Exchange(ctx, fmt.Sprintf("AT+CMGD=%d", index))
	return err
}
