//go:build linux

package at

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

// A session-leading gateway must not acquire the AT PTY as a controlling
// terminal: stopping the PTY bridge would then send SIGHUP before SIP cleanup.
func TestSerialDoesNotAcquireControllingTerminal(t *testing.T) {
	if path := os.Getenv("SIMHUB_TEST_PTY"); path != "" {
		client, err := OpenSerial(context.Background(), path, 115200)
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		data, err := os.ReadFile("/proc/self/stat")
		if err != nil {
			t.Fatal(err)
		}
		_, tail, ok := strings.Cut(string(data), ") ")
		if !ok {
			t.Fatal("invalid process stat")
		}
		fields := strings.Fields(tail)
		if len(fields) < 5 || fields[4] != "0" {
			t.Fatalf("serial port became controlling terminal: tty_nr=%v", fields[4])
		}
		return
	}
	master, err := unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(master)
	if err = unix.IoctlSetPointerInt(master, unix.TIOCSPTLCK, 0); err != nil {
		t.Fatal(err)
	}
	number, err := unix.IoctlGetInt(master, unix.TIOCGPTN)
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(os.Args[0], "-test.run=^TestSerialDoesNotAcquireControllingTerminal$")
	command.Env = append(os.Environ(), fmt.Sprintf("SIMHUB_TEST_PTY=/dev/pts/%d", number))
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("session leader serial test: %v\n%s", err, output)
	}
}
