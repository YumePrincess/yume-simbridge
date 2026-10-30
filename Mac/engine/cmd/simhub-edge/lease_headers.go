package main

import (
	"net/http"
	"os"
	"path/filepath"
)

func setLeaseHeaders(h http.Header) {
	h.Set("X-SimHub-Device", os.Getenv("SIMHUB_LEASE_DEVICE"))
	h.Set("X-SimHub-Session", os.Getenv("SIMHUB_LEASE_SESSION"))
	h.Set("X-SimHub-Epoch", os.Getenv("SIMHUB_LEASE_EPOCH"))
}

func databasePath(data string) string {
	if p := os.Getenv("SIMHUB_DATABASE"); p != "" {
		return p
	}
	return filepath.Join(data, "messages.sqlite")
}
