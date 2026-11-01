package main

import (
	"context"
	"log/slog"
	"net"
	"sort"
	"strings"
	"time"
)

func (e *engine) wakeRegistration() {
	select {
	case e.registrationWake <- struct{}{}:
	default:
	}
}

// The SIP socket binds all interfaces and can survive address changes. Its
// advertised NAT contact still needs a new REGISTER; pooled HTTP and the old
// push socket must reconnect. Never stop USB/audio or an active call here.
func (e *engine) networkChanged() {
	e.networkGeneration.Add(1)
	e.client.CloseIdleConnections()
	e.reconnectPush()
	e.registered.Store(false)
	e.wakeRegistration()
	e.cloudRecovered.Store(true)
	e.signalCloudWake()
	slog.Info("Network changed; reconnecting cloud push and SIP")
}

func (e *engine) reconnectPush() {
	e.wakeConnMu.Lock()
	if e.wakeConn != nil {
		e.wakeConn.Close()
	}
	e.wakeConnMu.Unlock()
	select {
	case e.pushReconnect <- struct{}{}:
	default:
	}
}

func networkFingerprint() string {
	// UDP connect selects the kernel's current IPv4 egress without sending a
	// packet or relying on DNS. Include interface addresses for VPN/LAN changes.
	conn, err := net.DialTimeout("udp4", "1.1.1.1:53", time.Second)
	if err != nil {
		return ""
	}
	local := conn.LocalAddr().(*net.UDPAddr).IP.String()
	conn.Close()
	addresses, _ := net.InterfaceAddrs()
	values := []string{local}
	for _, address := range addresses {
		values = append(values, address.String())
	}
	sort.Strings(values)
	return strings.Join(values, ",")
}

func (e *engine) networkRecoveryLoop(ctx context.Context) {
	previous := networkFingerprint()
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			current := networkFingerprint()
			if current != previous {
				previous = current
				e.networkChanged()
			}
		}
	}
}
