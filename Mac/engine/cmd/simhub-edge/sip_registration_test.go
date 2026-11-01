package main

import (
	"context"
	"fmt"
	"net"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/emiago/diago"
	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"
)

// Exercise the actual shared SIP stack. The registrar rejects stale digest
// headers and reused transaction branches, and observes endpoint bindings.
func TestRegistrationRefreshAndOwnedCleanup(t *testing.T) {
	registrar, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer registrar.Close()
	probe, err := net.ListenPacket("udp4", "0.0.0.0:0")
	if err != nil {
		t.Fatal(err)
	}
	port := probe.LocalAddr().(*net.UDPAddr).Port
	probe.Close()
	ua, err := sipgo.NewUA(sipgo.WithUserAgent("simhub"))
	if err != nil {
		t.Fatal(err)
	}
	defer ua.Close()
	client, err := sipgo.NewClient(ua, sipgo.WithClientNAT(), sipgo.WithClientConnectionAddr(fmt.Sprintf("0.0.0.0:%d", port)))
	if err != nil {
		t.Fatal(err)
	}
	dg := diago.NewDiago(ua, diago.WithClient(client), diago.WithTransport(diago.Transport{Transport: "udp4", BindHost: "0.0.0.0", BindPort: port}))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err = dg.ServeBackground(ctx, nil); err != nil {
		t.Fatal(err)
	}
	records := make(chan map[string]string, 12)
	go func() {
		seen := map[string]bool{}
		nonce := ""
		counter := 0
		for {
			buf := make([]byte, 8192)
			n, addr, err := registrar.ReadFrom(buf)
			if err != nil {
				return
			}
			lines := strings.Split(string(buf[:n]), "\r\n")
			h := map[string]string{}
			for _, line := range lines[1:] {
				k, v, ok := strings.Cut(line, ":")
				if ok {
					h[strings.ToLower(k)] = strings.TrimSpace(v)
				}
			}
			h["source"] = addr.String()
			records <- h
			status := "200 OK"
			extra := "Expires: 600\r\n"
			via := h["via"]
			branch := strings.Split(via, "branch=")[1]
			branch = strings.Split(branch, ";")[0]
			if seen[branch] {
				status = "400 Reused branch"
			}
			seen[branch] = true
			if h["proxy-authorization"] == "" {
				counter++
				nonce = fmt.Sprintf("nonce-%d", counter)
				status = "407 Proxy Authentication required"
				extra = fmt.Sprintf("Proxy-Authenticate: Digest realm=\"test\", nonce=\"%s\", algorithm=MD5, qop=\"auth\"\r\n", nonce)
			} else if !strings.Contains(h["proxy-authorization"], "nonce=\""+nonce+"\"") {
				status = "403 Stale authentication"
			}
			// Report the actual UDP mapping as a NAT registrar does.
			via += fmt.Sprintf(";received=127.0.0.1;rport=%d", addr.(*net.UDPAddr).Port)
			response := fmt.Sprintf("SIP/2.0 %s\r\nVia: %s\r\nFrom: %s\r\nTo: %s\r\nCall-ID: %s\r\nCSeq: %s\r\n%sContent-Length: 0\r\n\r\n", status, via, h["from"], h["to"], h["call-id"], h["cseq"], extra)
			registrar.WriteTo([]byte(response), addr)
		}
	}()
	uri := sip.Uri{User: "account", Host: "127.0.0.1", Port: registrar.LocalAddr().(*net.UDPAddr).Port}
	tr, err := dg.RegisterTransaction(ctx, uri, diago.RegisterOptions{Username: "account", Password: "secret", Expiry: 600 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	var callID, contact string
	for n := 0; n < 3; n++ {
		if err = registerSIP(ctx, tr); err != nil {
			t.Fatal(err)
		}
		initial, auth := <-records, <-records
		if initial["proxy-authorization"] != "" {
			t.Fatal("refresh reused previous authentication")
		}
		if !strings.HasSuffix(auth["source"], fmt.Sprintf(":%d", port)) {
			t.Fatalf("did not reuse listening socket: %s", auth["source"])
		}
		if n == 0 {
			callID = auth["call-id"]
			contact = auth["contact"]
		} else if auth["call-id"] != callID || auth["contact"] != contact {
			t.Fatal("refresh created another endpoint binding")
		}
	}
	if err = unregisterSIP(tr); err != nil {
		t.Fatal(err)
	}
	<-records
	last := <-records
	if last["expires"] != "0" || last["contact"] != contact || last["contact"] == "*" {
		t.Fatalf("cleanup must remove only owned Contact: %v", last)
	}
}

func TestRegistrationTransientGraceIsBoundedAndRejectsHardFailures(t *testing.T) {
	now := time.Now()
	forbidden := &diago.RegisterResponseError{RegisterRes: &sip.Response{StatusCode: 403}}
	for _, tc := range []struct {
		last     time.Time
		err      error
		failures int
		want     bool
	}{
		{time.Time{}, context.DeadlineExceeded, 1, false},
		{now.Add(-45 * time.Second), context.DeadlineExceeded, 1, true},
		{now.Add(-61 * time.Second), context.DeadlineExceeded, 1, false},
		{now, context.DeadlineExceeded, 3, false},
		{now, fmt.Errorf("sendto: %w", syscall.EPERM), 1, false},
		{now, forbidden, 1, false},
	} {
		if got := registrationStillValid(tc.last, now, tc.err, tc.failures); got != tc.want {
			t.Fatalf("last=%v error=%v failures=%d got=%v", tc.last, tc.err, tc.failures, got)
		}
	}
}

func TestRegistrationFailureBackoff(t *testing.T) {
	forbidden := &diago.RegisterResponseError{RegisterRes: &sip.Response{StatusCode: 403}}
	if registrationDelay(forbidden, 1) != time.Minute {
		t.Fatal("403 must not produce a rapid reconnect loop")
	}
	if registrationDelay(fmt.Errorf("offline"), 8) != time.Minute {
		t.Fatal("network backoff must be bounded")
	}
	if registrationDelay(nil, 0) != 30*time.Second {
		t.Fatal("successful refresh must keep NAT reachable")
	}
}
