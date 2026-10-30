package at

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

type ModuleCallRecord struct {
	Storage string `json:"storage"`
	Index   int    `json:"index"`
	Raw     string `json:"raw"`
}

func parseCallRecords(storage string, lines []string) []ModuleCallRecord {
	result := []ModuleCallRecord{}
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "+CPBR:") {
			continue
		}
		first := strings.SplitN(strings.TrimSpace(strings.TrimPrefix(line, "+CPBR:")), ",", 2)
		index, err := strconv.Atoi(first[0])
		if err == nil && index > 0 && index <= 1000 && len(first) == 2 {
			result = append(result, ModuleCallRecord{storage, index, line})
		}
	}
	return result
}
func (a *Adapter) ModuleCallHistory(ctx context.Context) ([]ModuleCallRecord, error) {
	defer a.client.Exchange(ctx, `AT+CPBS="SM"`)
	result := []ModuleCallRecord{}
	for _, storage := range []string{"DC", "RC", "MC"} {
		if _, err := a.client.Exchange(ctx, fmt.Sprintf(`AT+CPBS="%s"`, storage)); err != nil {
			continue
		}
		lines, err := a.client.Exchange(ctx, "AT+CPBR=?")
		if err != nil {
			continue
		}
		bounds := regexp.MustCompile(`\((\d+)-(\d+)\)`).FindStringSubmatch(strings.Join(lines, "\n"))
		if len(bounds) != 3 {
			continue
		}
		end, _ := strconv.Atoi(bounds[2])
		if end > 1000 || end < 1 {
			continue
		}
		lines, err = a.client.Exchange(ctx, fmt.Sprintf("AT+CPBR=%s,%s", bounds[1], bounds[2]))
		if err != nil {
			continue
		}
		result = append(result, parseCallRecords(storage, lines)...)
	}
	return result, nil
}
func (a *Adapter) DeleteCallHistoryIfMatches(ctx context.Context, record ModuleCallRecord) error {
	if record.Storage != "DC" && record.Storage != "RC" && record.Storage != "MC" {
		return errors.New("not a call history storage")
	}
	if record.Index < 1 || record.Index > 1000 {
		return errors.New("invalid call history index")
	}
	defer a.client.Exchange(ctx, `AT+CPBS="SM"`)
	if _, err := a.client.Exchange(ctx, fmt.Sprintf(`AT+CPBS="%s"`, record.Storage)); err != nil {
		return err
	}
	lines, err := a.client.Exchange(ctx, fmt.Sprintf("AT+CPBR=%d", record.Index))
	if err != nil {
		return err
	}
	current := parseCallRecords(record.Storage, lines)
	if len(current) != 1 || current[0] != record {
		return errors.New("call history slot changed; retained")
	}
	_, err = a.client.Exchange(ctx, fmt.Sprintf("AT+CPBW=%d", record.Index))
	return err
}
