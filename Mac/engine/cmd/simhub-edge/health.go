package main

import (
	"encoding/json"
	"os"
	"time"
)

func writeHealth(path string, value any) {
	b, err := json.Marshal(value)
	if err != nil {
		return
	}
	if os.WriteFile(path+".tmp", b, 0600) == nil {
		_ = os.Rename(path+".tmp", path)
	}
}
func audioHealthy(path string, now time.Time) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var h struct {
		Updated int64 `json:"updated"`
		Ready   bool  `json:"ready"`
	}
	if json.Unmarshal(b, &h) != nil {
		return false
	}
	age := now.UnixMilli() - h.Updated
	return h.Ready && age >= 0 && age < 4000
}
