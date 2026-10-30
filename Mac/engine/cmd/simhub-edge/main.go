package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/cellbridge/cellbridge/gateway/internal/db"
	"github.com/cellbridge/cellbridge/gateway/internal/modem"
	"github.com/cellbridge/cellbridge/gateway/internal/modem/at"
	"github.com/cellbridge/cellbridge/gateway/internal/sms"
	"github.com/emiago/diago"
	"github.com/emiago/diago/audio"
	"github.com/emiago/diago/media"
	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"
)

var Version = "27.2.0"
var Build = "27028"

type bootstrap struct {
	Origin string `json:"origin"`
	Token  string `json:"token"`
}
type sipConfig struct {
	Domain   string `json:"domain"`
	User     string `json:"user"`
	Password string `json:"password"`
}
type job struct {
	ID      string `json:"id"`
	Payload string `json:"payload"`
}
type syncReply struct {
	Job             *job      `json:"job"`
	SIP             sipConfig `json:"sip"`
	InboundEnabled  bool      `json:"inboundEnabled"`
	OutboundEnabled bool      `json:"outboundEnabled"`
}
type engine struct {
	rootCtx                             context.Context
	boot                                bootstrap
	modem                               *at.Adapter
	database                            *db.DB
	sms                                 *sms.Engine
	client                              *http.Client
	dg                                  *diago.Diago
	sipMu                               sync.RWMutex
	sip                                 sipConfig
	busy                                atomic.Bool
	registered                          atomic.Bool
	inbound                             atomic.Bool
	voiceReady                          atomic.Bool
	cloudPolicy                         syncPolicy
	cloudWake                           atomic.Bool
	jobWake                             atomic.Bool
	wakeConnected                       atomic.Bool
	wakeCh                              chan struct{}
	wakeStamp                           int64
	cloudSyncCount                      uint64
	callMu                              sync.Mutex
	callID                              modem.CallID
	callCancel                          context.CancelFunc
	rxPath, txPath, python, routeScript string
	healthDir                           string
}

func main() {
	cfg := flag.String("config", "", "private bootstrap JSON")
	tty := flag.String("tty", "", "AT PTY")
	data := flag.String("data", "", "private data directory")
	rx := flag.String("rx", "", "PCM capture FIFO")
	tx := flag.String("tx", "", "PCM playback FIFO")
	py := flag.String("python", "python3", "Python interpreter")
	route := flag.String("route", "", "route reset script")
	flag.Parse()
	if os.Getenv("SIMHUB_LEASE_SESSION") == "" {
		fatal(errors.New("start runtime through the ownership supervisor"))
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	b, err := os.ReadFile(*cfg)
	if err != nil {
		fatal(err)
	}
	var boot bootstrap
	if err = json.Unmarshal(b, &boot); err != nil {
		fatal(err)
	}
	if boot.Origin != "https://worker.example.com" || len(boot.Token) < 32 {
		fatal(errors.New("invalid bootstrap"))
	}
	if err = os.MkdirAll(*data, 0700); err != nil {
		fatal(err)
	}
	database, err := db.Open(databasePath(*data))
	if err != nil {
		fatal(err)
	}
	defer database.Close()
	if err = database.Migrate(ctx); err != nil {
		fatal(err)
	}
	_, err = database.Exec(`CREATE TABLE IF NOT EXISTS edge_jobs (id TEXT PRIMARY KEY,status TEXT NOT NULL,result TEXT NOT NULL DEFAULT '',acked INTEGER NOT NULL DEFAULT 0);CREATE TABLE IF NOT EXISTS uploaded (id TEXT PRIMARY KEY);CREATE TABLE IF NOT EXISTS cloud_delivered (id TEXT PRIMARY KEY);CREATE TABLE IF NOT EXISTS edge_sms_owned (job_id TEXT PRIMARY KEY,message_id TEXT NOT NULL);`)
	if err != nil {
		fatal(err)
	}
	// An interrupted submission is never submitted a second time.
	_, err = database.Exec("UPDATE edge_jobs SET status='unknown',result='Process exited during submission; review before retry' WHERE status='running'")
	if err != nil {
		fatal(err)
	}
	port, err := at.OpenSerial(ctx, *tty, 115200)
	if err != nil {
		fatal(err)
	}
	adapter := at.NewAdapter(port)
	defer adapter.Close()
	go adapter.Run(ctx)
	probeCtx, stop := context.WithTimeout(ctx, 20*time.Second)
	_, err = adapter.Probe(probeCtx)
	stop()
	if err != nil {
		slog.Warn("modem probe failed", "error", err)
	}
	e := &engine{wakeCh: make(chan struct{}, 1), rootCtx: ctx, boot: boot, modem: adapter, database: database, sms: sms.NewEngine(database, adapter), client: &http.Client{Timeout: 15 * time.Second}, rxPath: *rx, txPath: *tx, python: *py, routeScript: *route, healthDir: *data}
	e.voiceReady.Store(*rx != "" && *tx != "")
	ua, err := sipgo.NewUA(sipgo.WithUserAgent("simhub"))
	if err != nil {
		fatal(err)
	}
	defer ua.Close()
	e.dg = diago.NewDiago(ua, diago.WithTransport(diago.Transport{Transport: "udp", BindHost: "0.0.0.0", BindPort: 15060, RewriteContact: true}), diago.WithMediaConfig(diago.MediaConfig{Codecs: []media.Codec{media.CodecAudioUlaw, media.CodecAudioAlaw, media.CodecTelephoneEvent8000}}))
	go func() {
		if err := e.dg.Serve(ctx, e.outgoing); err != nil && !errors.Is(err, context.Canceled) {
			slog.Error("SIP listener stopped", "error", err)
			cancel()
		}
	}()
	go e.cloudWakeLoop(ctx)
	go e.voiceRecoveryLoop(ctx)
	go e.modemEvents(ctx)
	go e.registerLoop(ctx)
	go e.inboxLoop(ctx)
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		e.sync(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-e.wakeCh:
		}
	}
}
func fatal(err error) { slog.Error("edge stopped", "error", err); os.Exit(1) }
func (e *engine) api(ctx context.Context, path string, input, output any) error {
	b, err := json.Marshal(input)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, "POST", e.boot.Origin+path, bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	setLeaseHeaders(req.Header)
	req.Header.Set("Authorization", "Bearer "+e.boot.Token)
	r, err := e.client.Do(req)
	if err != nil {
		return err
	}
	defer r.Body.Close()
	if r.StatusCode >= 300 {
		return fmt.Errorf("cloud request %s: HTTP %d", path, r.StatusCode)
	}
	if output != nil {
		return json.NewDecoder(io.LimitReader(r.Body, 32768)).Decode(output)
	}
	return nil
}
func (e *engine) sync(ctx context.Context) {
	statusCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
	status, err := e.modem.Status(statusCtx)
	cancel()
	if err != nil {
		status.SIM = "unavailable"
		status.Registration = "unknown"
		slog.Warn("modem status unavailable")
	}
	var reply syncReply
	connected := err == nil
	voice := connected && e.voiceReady.Load() && audioHealthy(filepath.Join(e.healthDir, "audio-health.json"), time.Now())
	health := map[string]any{"modemConnected": connected, "sim": status.SIM, "operator": status.Operator, "registration": status.Registration, "signal": status.Signal, "voiceReady": voice, "sipRegistered": e.registered.Load(), "busy": connected && e.busy.Load(), "version": Version + " (" + Build + ")", "updated": time.Now().UnixMilli(), "heartbeatSeconds": 30, "cloudSyncCount": e.cloudSyncCount, "cloudPushConnected": e.wakeConnected.Load()}
	writeHealth(filepath.Join(e.healthDir, "edge-health.json"), health)
	state := cloudSyncState{connected, voice, e.registered.Load(), connected && e.busy.Load(), string(status.SIM), string(status.Registration)}
	wake := e.cloudWake.Swap(false)
	if info, statErr := os.Stat(filepath.Join(e.healthDir, "cloud-wake")); statErr == nil && info.ModTime().UnixNano() != e.wakeStamp {
		e.wakeStamp = info.ModTime().UnixNano()
		wake = true
	}
	if !e.cloudPolicy.due(time.Now(), state, wake) {
		if wake {
			e.cloudWake.Store(true)
		}
		return
	}
	claim := e.jobWake.Swap(false) || !e.wakeConnected.Load()
	health["claimJobs"] = claim
	e.cloudSyncCount++
	err = e.api(ctx, "/edge/sync", health, &reply)
	e.cloudPolicy.complete(time.Now(), state, err == nil, reply.Job != nil)
	if err != nil {
		if claim {
			e.jobWake.Store(true)
		}
		slog.Warn("cloud disconnected", "error", err)
		return
	}
	e.sipMu.Lock()
	e.sip = reply.SIP
	e.sipMu.Unlock()
	e.inbound.Store(reply.InboundEnabled)
	e.uploadMessages(ctx)
	e.uploadResults(ctx)
	if reply.Job != nil {
		e.jobWake.Store(true)
		e.sendSMS(ctx, *reply.Job)
	}
}
func (e *engine) sendSMS(ctx context.Context, j job) {
	result, err := e.database.ExecContext(ctx, "INSERT OR IGNORE INTO edge_jobs(id,status) VALUES(?,'running')", j.ID)
	if err != nil {
		return
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return
	}
	var p struct{ To, Body string }
	if err = json.Unmarshal([]byte(j.Payload), &p); err != nil {
		e.saveResult(j.ID, "failed", "Invalid job")
		return
	}
	if !regexp.MustCompile(`^(\+[1-9]\d{6,14}|[0-9]{1,20})$`).MatchString(p.To) || len(p.Body) == 0 || len([]rune(p.Body)) > 2000 {
		e.saveResult(j.ID, "failed", "Invalid SMS payload")
		return
	}
	sendCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	m, err := e.sms.Send(sendCtx, p.To, p.Body)
	if m != nil {
		_, _ = e.database.ExecContext(ctx, "INSERT OR REPLACE INTO edge_sms_owned(job_id,message_id) VALUES(?,?)", j.ID, m.ID)
	}
	status := "sent"
	reason := "Accepted by modem (delivery not confirmed)"
	if err != nil {
		status = "unknown"
		reason = "Submission interrupted; review local history before retry"
	} else if m.Status != "sent" {
		status = "unknown"
		reason = "Partial or uncertain modem submission"
	}
	e.saveResult(j.ID, status, reason)
	e.uploadResults(ctx)
}
func (e *engine) saveResult(id, status, reason string) {
	_, err := e.database.Exec("UPDATE edge_jobs SET status=?,result=?,acked=0 WHERE id=?", status, reason, id)
	if err != nil {
		slog.Error("persist SMS result failed")
	}
}
func (e *engine) uploadResults(ctx context.Context) {
	rows, err := e.database.QueryContext(ctx, "SELECT id,status,result FROM edge_jobs WHERE acked=0 AND status<>'running' LIMIT 10")
	if err != nil {
		return
	}
	type result struct{ ID, Status, Result string }
	var items []result
	for rows.Next() {
		var r result
		if rows.Scan(&r.ID, &r.Status, &r.Result) == nil {
			items = append(items, r)
		}
	}
	rows.Close()
	for _, r := range items {
		if e.api(ctx, "/edge/result", map[string]string{"id": r.ID, "status": r.Status, "result": r.Result}, nil) == nil {
			_, _ = e.database.ExecContext(ctx, "UPDATE edge_jobs SET acked=1 WHERE id=?", r.ID)
			if r.Status == "sent" {
				e.cleanupStoredSMS(ctx)
			}
		}
	}
}
func (e *engine) inboxLoop(ctx context.Context) {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		if !e.busy.Load() {
			c, cancel := context.WithTimeout(ctx, 12*time.Second)
			raws, _, err := e.modem.ListSMS(c, "")
			if err == nil {
				for _, raw := range raws {
					// Clear only this exact PDU after durable cloud delivery.
					if e.smsDelivered(c, raw.RawPDU) || e.ownedSentPDU(c, raw) {
						if err = e.modem.DeleteSMSIfMatches(c, raw.ModemIndex, raw.RawPDU); err != nil {
							slog.Warn("SMS cleanup deferred")
						}
						continue
					}
					if _, err = e.sms.Ingest(c, raw); err != nil {
						slog.Warn("SMS decode deferred", "error", err)
					}
				}
			}
			cancel()
			var pending int
			if e.database.QueryRowContext(ctx, "SELECT COUNT(*) FROM messages WHERE direction='inbound' AND id NOT IN (SELECT id FROM cloud_delivered)").Scan(&pending) == nil && pending > 0 {
				e.cloudWake.Store(true)
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
func (e *engine) uploadMessages(ctx context.Context) {
	rows, err := e.database.QueryContext(ctx, "SELECT id,peer,body FROM messages WHERE direction='inbound' AND id NOT IN (SELECT id FROM cloud_delivered) LIMIT 10")
	if err != nil {
		return
	}
	type message struct{ ID, From, Body string }
	var items []message
	for rows.Next() {
		var m message
		if rows.Scan(&m.ID, &m.From, &m.Body) == nil {
			items = append(items, m)
		}
	}
	rows.Close()
	deliveredAny := false
	for _, m := range items {
		hashes, hashErr := e.database.QueryContext(ctx, "SELECT pdu_hash FROM sms_segments WHERE message_id=? ORDER BY pdu_hash", m.ID)
		if hashErr != nil {
			continue
		}
		parts := []string{}
		for hashes.Next() {
			var hash string
			if hashes.Scan(&hash) == nil {
				parts = append(parts, hash)
			}
		}
		hashes.Close()
		if len(parts) == 0 {
			continue
		}
		fingerprint := smsReceiptFingerprint(parts)
		var receipt struct {
			Delivered      bool `json:"delivered"`
			CleanupAllowed bool `json:"cleanupAllowed"`
		}
		if e.api(ctx, "/edge/sms", map[string]string{"id": m.ID, "from": m.From, "body": m.Body, "fingerprint": fingerprint}, &receipt) == nil && (receipt.Delivered || receipt.CleanupAllowed) {
			_, _ = e.database.ExecContext(ctx, "INSERT OR IGNORE INTO cloud_delivered(id) VALUES(?)", m.ID)
			deliveredAny = true
		}
	}
	if deliveredAny {
		e.cleanupStoredSMS(ctx)
	}
}
func (e *engine) getSIP() sipConfig { e.sipMu.RLock(); defer e.sipMu.RUnlock(); return e.sip }
func (e *engine) registerLoop(ctx context.Context) {
	for {
		c := e.getSIP()
		if c.Domain != "" && c.Password != "" {
			var uri sip.Uri
			err := sip.ParseUri("sip:"+c.User+"@"+c.Domain, &uri)
			if err == nil {
				// Re-register on the same socket so the registrar can address its NAT mapping.
				regCtx, cancel := context.WithCancel(ctx)
				go func() {
					t := time.NewTicker(5 * time.Second)
					defer t.Stop()
					for {
						select {
						case <-regCtx.Done():
							return
						case <-t.C:
							if e.getSIP() != c {
								cancel()
								return
							}
						}
					}
				}()
				tr, err := e.dg.RegisterTransaction(regCtx, uri, diago.RegisterOptions{Username: c.User, Password: c.Password, Expiry: 3600 * time.Second})
				if err == nil {
					err = tr.Register(regCtx)
					if err == nil {
						e.registered.Store(true)
						slog.Info("Twilio SIP registered")
						for err == nil {
							select {
							case <-regCtx.Done():
								err = regCtx.Err()
							case <-time.After(30 * time.Second):
								checkCtx, done := context.WithTimeout(regCtx, 8*time.Second)
								err = tr.Register(checkCtx)
								done()
							}
						}
					}
				}
				e.registered.Store(false)
				cancel()
				if err != nil && !errors.Is(err, context.Canceled) {
					slog.Warn("SIP registration failed", "error", err)
				}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(10 * time.Second):
		}
	}
}
func (e *engine) setCall(id modem.CallID, cancel context.CancelFunc) {
	e.callMu.Lock()
	e.callID = id
	e.callCancel = cancel
	e.callMu.Unlock()
}
func (e *engine) modemEvents(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case ev, ok := <-e.modem.Events():
			if !ok {
				return
			}
			switch ev.Kind {
			case "incoming":
				go e.incoming(ctx, ev)
			case "ended":
				e.callMu.Lock()
				if ev.CallID == e.callID && e.callCancel != nil {
					e.callCancel()
				}
				e.callMu.Unlock()
			}
		}
	}
}
func (e *engine) resetRoute() {
	if e.routeScript == "" {
		return
	}
	parent := e.rootCtx
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, 45*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, e.python, "-s", "-B", e.routeScript)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		e.voiceReady.Store(false)
		slog.Warn("voice route reset failed")
	} else {
		e.voiceReady.Store(true)
	}
}
func (e *engine) finishCall(id modem.CallID) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	_ = e.modem.Hangup(ctx, id)
	e.setCall("", nil)
	e.resetRoute()
	e.busy.Store(false)
}
func (e *engine) callEvent(id, status string) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = e.api(ctx, "/edge/call-event", map[string]string{"id": id, "status": status}, nil)
}
func (e *engine) incoming(parent context.Context, ev modem.ModemEvent) {
	if !e.inbound.Load() || !e.registered.Load() || !e.voiceReady.Load() || !e.busy.CompareAndSwap(false, true) {
		return
	}
	ctx, cancel := context.WithTimeout(parent, 2*time.Hour)
	defer cancel()
	e.setCall(ev.CallID, cancel)
	defer e.finishCall(ev.CallID)
	var ticket struct {
		ID         string `json:"id"`
		AnswerMode string `json:"answerMode"`
	}
	if e.api(ctx, "/edge/incoming", map[string]string{"from": ev.Peer}, &ticket) != nil {
		return
	}
	// Missing mode means an older Worker: preserve its original early-answer
	// behavior. Updated Workers pin the chosen mode to this one-use ticket.
	deferred := ticket.AnswerMode == "confirmed"
	callFinished := false
	defer func() {
		if !callFinished {
			e.callEvent(ticket.ID, "failed")
		}
	}()
	stopRinging := func() {}
	if deferred {
		stopRinging = watchIncomingRinging(ctx, cancel, func(checkCtx context.Context) (bool, error) {
			return e.modem.IncomingRinging(checkCtx, ev.CallID)
		})
		defer stopRinging()
	}
	finishWaiting := func() {}
	if !deferred {
		if err := e.answerIncoming(ctx, ev.CallID); err != nil {
			return
		}
		waitingCtx, stopWaiting := context.WithCancel(ctx)
		waitingDone := make(chan struct{})
		introDone := make(chan struct{})
		go func() {
			defer close(waitingDone)
			if err := e.waitingAudio(waitingCtx, introDone); err != nil && !errors.Is(err, context.Canceled) {
				cancel()
			}
		}()
		var waitingOnce sync.Once
		finishWaiting = func() { waitingOnce.Do(func() { stopWaiting(); <-waitingDone }) }
		defer finishWaiting()
		select {
		case <-ctx.Done():
			return
		case <-introDone:
		}
	}
	c := e.getSIP()
	var uri sip.Uri
	if sip.ParseUri("sip:incoming@"+c.Domain, &uri) != nil {
		return
	}
	dialCtx, stop := context.WithTimeout(ctx, 150*time.Second)
	d, med, err := e.dg.Invite(dialCtx, uri, diago.InviteOptions{Username: c.User, Password: c.Password, Headers: []sip.Header{sip.NewHeader("X-Bridge", ticket.ID)}})
	stop()
	if err != nil {
		return
	}
	defer d.Close()
	defer med.Close()
	defer hangup(d)
	stopRemoteWatch := context.AfterFunc(d.Context(), cancel)
	defer stopRemoteWatch()
	finishWaiting()
	if deferred {
		// Failed TwiML, voicemail or network answer must never cause ATA.
		if err := answerAfterConfirmation(ctx, func(checkCtx context.Context) (bool, error) {
			var result struct {
				Accepted bool `json:"accepted"`
			}
			err := e.api(checkCtx, "/edge/incoming-ready", map[string]string{"id": ticket.ID}, &result)
			return result.Accepted, err
		}, func(answerCtx context.Context) error {
			stopRinging()
			ringCtx, endRingCheck := context.WithTimeout(answerCtx, 4*time.Second)
			stillRinging, err := e.modem.IncomingRinging(ringCtx, ev.CallID)
			endRingCheck()
			if err != nil {
				return err
			}
			if !stillRinging {
				return errors.New("SIM caller is no longer ringing")
			}
			return e.answerIncoming(answerCtx, ev.CallID)
		}); err != nil {
			return
		}
	}
	e.callEvent(ticket.ID, "connected")
	_ = e.bridge(ctx, d.Context(), med, ev.CallID, nil)
	callFinished = true
	e.callEvent(ticket.ID, "ended")
}
func (e *engine) outgoing(d *diago.DialogServerSession) {
	defer d.Close()
	if !e.voiceReady.Load() || !e.busy.CompareAndSwap(false, true) {
		_ = d.Respond(486, "Busy Here", nil)
		return
	}
	ctx, cancel := context.WithTimeout(d.Context(), 2*time.Hour)
	defer cancel()
	var id modem.CallID
	defer func() {
		if id != "" {
			e.finishCall(id)
		} else {
			e.busy.Store(false)
		}
	}()
	h := d.InviteRequest.GetHeader("X-Job")
	if h == nil {
		_ = d.Respond(403, "Forbidden", nil)
		return
	}
	ticket := h.Value()
	var target struct {
		To string `json:"to"`
	}
	if e.api(ctx, "/edge/authorize", map[string]string{"id": ticket}, &target) != nil {
		_ = d.Respond(403, "Forbidden", nil)
		return
	}
	if !regexp.MustCompile(`^(\+[1-9]\d{6,14}|[0-9]{1,20})$`).MatchString(target.To) {
		_ = d.Respond(403, "Forbidden", nil)
		return
	}
	_ = d.Trying()
	var err error
	id, err = e.modem.Dial(ctx, target.To)
	if err != nil {
		_ = d.Respond(503, "Modem unavailable", nil)
		e.callEvent(ticket, "failed")
		return
	}
	e.setCall(id, cancel)
	// Establish RTP with 183 before CLCC becomes active: carrier ringback and
	// failure announcements are often early media, never an answered call.
	med, err := d.ProgressMedia(diago.ProgressMediaOptions{RTPNAT: media.RTPNATSymetric})
	if err != nil {
		if med != nil {
			_ = med.Close()
		}
		_ = d.Respond(503, "Media unavailable", nil)
		e.callEvent(ticket, "failed")
		return
	}
	defer med.Close()
	bridgeCtx, stopBridge := context.WithCancel(ctx)
	bridgeDone := make(chan struct{})
	ringback := newWaitingRingback(time.Now())
	defer ringback.waiting.Store(false)
	go func() {
		defer close(bridgeDone)
		_ = e.bridge(bridgeCtx, d.Context(), med, id, ringback)
		// A broken audio path must not leave CLCC polling or the SIM call alive.
		cancel()
	}()
	defer func() { stopBridge(); <-bridgeDone }()
	activeCtx, stop := context.WithTimeout(ctx, 110*time.Second)
	ok, err := e.modem.WaitActive(activeCtx)
	ringback.waiting.Store(false)
	stop()
	if err != nil || !ok {
		_ = d.Respond(480, "Temporarily Unavailable", nil)
		e.callEvent(ticket, "failed")
		return
	}
	// Promote the SAME RTP session, preserving audio across 183 -> 200.
	if err = d.AnswerEarlyMedia(med, diago.AnswerOptions{}); err != nil {
		e.callEvent(ticket, "failed")
		return
	}
	defer hangup(d)
	e.callEvent(ticket, "connected")
	<-bridgeDone
	e.callEvent(ticket, "ended")
}

type dialog interface{ Hangup(context.Context) error }

func hangup(d dialog) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = d.Hangup(ctx)
}
func (e *engine) bridge(ctx, dialogCtx context.Context, med *diago.DialogMedia, id modem.CallID, ringback *waitingRingback) error {
	// O_NONBLOCK prevents open() hanging if the CoreAudio helper has exited.
	rx, err := os.OpenFile(e.rxPath, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	defer rx.Close()
	drain := make([]byte, 4096)
	for {
		n, err := syscall.Read(int(rx.Fd()), drain)
		if err != nil || n <= 0 {
			break
		}
	}
	tx, err := os.OpenFile(e.txPath, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return err
	}
	defer tx.Close()
	// Twilio may not send RTP until answer. Wake idle CoreAudio capture now
	// so its carrier -> caller direction does not depend on caller audio.
	if _, err := tx.Write(make([]byte, 320)); err != nil && !errors.Is(err, syscall.EAGAIN) {
		return err
	}
	dtmf, err := med.AudioReaderDTMF()
	if err != nil {
		return err
	}
	relay := newToneRelay(ctx, e.modem, id)
	defer relay.close()
	dtmf.OnDTMF(relay.enqueue)

	props := diago.MediaProps{}
	_, err = med.AudioReader(diago.WithAudioReaderMediaProps(&props))
	if err != nil {
		return err
	}
	decoder, err := audio.NewPCMDecoderReader(props.Codec.PayloadType, dtmf)
	if err != nil {
		return err
	}
	writer, err := med.AudioWriter()
	if err != nil {
		return err
	}
	encoder, err := audio.NewPCMEncoderWriter(props.Codec.PayloadType, writer)
	if err != nil {
		return err
	}
	errCh := make(chan error, 2)
	bridgeCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var fromSIP, toModem, fromModem, toSIP atomic.Int64
	slog.Info("audio bridge started", "codec", props.Codec.PayloadType)
	report := func() {
		health := map[string]any{"updated": time.Now().UnixMilli(), "sipDecodedBytes": fromSIP.Load(), "usbPlaybackBytes": toModem.Load(), "usbCaptureBytes": fromModem.Load(), "sipEncodedBytes": toSIP.Load()}
		writeHealth(filepath.Join(e.healthDir, "call-media.json"), health)
		slog.Info("audio bridge counters", "sip_to_mac", fromSIP.Load(), "mac_to_usb", toModem.Load(), "usb_to_mac", fromModem.Load(), "mac_to_sip", toSIP.Load())
	}
	defer report()
	var wg sync.WaitGroup
	wg.Add(3)
	go func() {
		defer wg.Done()
		t := time.NewTicker(5 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-bridgeCtx.Done():
				return
			case <-t.C:
				report()
			}
		}
	}()
	go func() {
		defer wg.Done()
		buf := make([]byte, 6400)
		for {
			n, err := decoder.Read(buf)
			if err != nil {
				errCh <- err
				return
			}
			if n > 0 {
				fromSIP.Add(int64(n))
				written, writeErr := tx.Write(buf[:n])
				toModem.Add(int64(written))
				if err = writeErr; err != nil && !errors.Is(err, syscall.EAGAIN) {
					errCh <- err
					return
				}
			}
		}
	}()
	go func() {
		defer wg.Done()
		ticker := time.NewTicker(20 * time.Millisecond)
		defer ticker.Stop()
		buf := make([]byte, 320)
		for {
			select {
			case <-bridgeCtx.Done():
				return
			case <-ticker.C:
				clear(buf)
				n, err := syscall.Read(int(rx.Fd()), buf)
				if err != nil && !errors.Is(err, syscall.EAGAIN) {
					errCh <- err
					return
				}
				if n < 0 {
					n = 0
				}
				fromModem.Add(int64(n))
				ringback.fill(buf, time.Now())
				encoded, writeErr := encoder.Write(buf)
				toSIP.Add(int64(encoded))
				if err = writeErr; err != nil {
					errCh <- err
					return
				}
			}
		}
	}()
	select {
	case <-ctx.Done():
		err = ctx.Err()
	case <-dialogCtx.Done():
		err = dialogCtx.Err()
	case err = <-errCh:
	}
	cancel()
	_ = med.Close()
	_ = rx.Close()
	_ = tx.Close()
	wg.Wait()
	if err != nil && !errors.Is(err, context.Canceled) {
		slog.Warn("audio bridge ended", "error", err)
	}
	return err
}
