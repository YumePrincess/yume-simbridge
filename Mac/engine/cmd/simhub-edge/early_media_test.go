package main

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/emiago/diago"
	"github.com/emiago/diago/media"
	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"
)

// Exercise the actual SIP library and RTP transport: audio must arrive before
// any 200 response, and promotion must preserve the negotiated RTP session.
func TestCarrierAudioBeforeAnswerAndAfterPromotion(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	makeEndpoint := func() (*diago.Diago, int) {
		socket, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		port := socket.LocalAddr().(*net.UDPAddr).Port
		socket.Close()
		ua, err := sipgo.NewUA()
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { ua.Close() })
		return diago.NewDiago(ua, diago.WithTransport(diago.Transport{Transport: "udp", BindHost: "127.0.0.1", BindPort: port})), port
	}
	server, port := makeEndpoint()
	sessions := make(chan *diago.DialogServerSession, 1)
	if err := server.ServeBackground(ctx, func(d *diago.DialogServerSession) { sessions <- d; <-d.Context().Done() }); err != nil {
		t.Fatal(err)
	}
	client, _ := makeEndpoint()
	if err := client.ServeBackground(ctx, nil); err != nil {
		t.Fatal(err)
	}
	type result struct {
		d   *diago.DialogClientSession
		m   *diago.DialogMedia
		err error
	}
	dialed := make(chan result, 1)
	go func() {
		d, err := client.NewDialog(sip.Uri{User: "test", Host: "127.0.0.1", Port: port}, diago.NewDialogOptions{})
		if err != nil {
			dialed <- result{err: err}
			return
		}
		m, err := d.Invite(ctx, diago.InviteClientOptions{EarlyMediaDetect: true})
		dialed <- result{d, m, err}
	}()
	var d *diago.DialogServerSession
	select {
	case d = <-sessions:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	defer d.Close()
	m, err := d.ProgressMedia(diago.ProgressMediaOptions{RTPNAT: media.RTPNATSymetric})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	var r result
	select {
	case r = <-dialed:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if !errors.Is(r.err, diago.ErrClientEarlyMedia) {
		t.Fatalf("expected 183 before answer, got %v", r.err)
	}
	defer r.d.Close()
	defer r.m.Close()
	reader, err := r.m.AudioReader()
	if err != nil {
		t.Fatal(err)
	}
	writer, err := m.AudioWriter()
	if err != nil {
		t.Fatal(err)
	}
	verifyAudio := func(marker byte) {
		got := make(chan []byte, 1)
		go func() { buf := make([]byte, 160); n, _ := reader.Read(buf); got <- buf[:n] }()
		packet := make([]byte, 160)
		for i := range packet {
			packet[i] = marker
		}
		if _, err := writer.Write(packet); err != nil {
			t.Fatal(err)
		}
		select {
		case buf := <-got:
			if len(buf) != 160 || buf[0] != marker {
				t.Fatalf("audio marker lost: %v", buf)
			}
		case <-ctx.Done():
			t.Fatal("RTP audio missing")
		}
	}
	verifyAudio(0x31)
	answered := make(chan error, 1)
	go func() {
		// SDP is unchanged in the final answer. Wait at the SIP layer so
		// the test peer does not mutate the live RTP remote address.
		err := r.d.DialogClientSession.WaitAnswer(ctx, sipgo.AnswerOptions{})
		if err == nil {
			err = r.d.Ack(ctx)
		}
		answered <- err
	}()
	if err := d.AnswerEarlyMedia(m, diago.AnswerOptions{}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-answered:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	verifyAudio(0x42)
	_ = d.Hangup(ctx)
}
