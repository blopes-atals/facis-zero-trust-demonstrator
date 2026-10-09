package atls_test

// Tests for the resource and timing bounds of the listener and Dial: connections waiting for a
// handshake slot, connections nobody accepts before their validity ends, and peer verification
// within the handshake deadline and slot.

import (
	"bytes"
	"errors"
	"net"
	"os"
	"runtime"
	"testing"
	"time"

	"github.com/eclipse-xfsc/facis-zero-trust-demonstrator/internal/atls"
)

// listenerHandlers counts the goroutines that handle one incoming connection of a listener.
func listenerHandlers() int {
	buf := make([]byte, 1<<22)
	buf = buf[:runtime.Stack(buf, true)]
	n := 0
	for _, g := range bytes.Split(buf, []byte("\n\n")) {
		if bytes.Contains(g, []byte("atls.(*Listener).handle(")) {
			n++
		}
	}
	return n
}

// openDescriptors counts the open file descriptors of the process.
func openDescriptors(t *testing.T) int {
	t.Helper()
	entries, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		t.Skipf("cannot count descriptors: %v", err)
	}
	return len(entries)
}

// More clients than the cap connect and stay silent. The listener holds a goroutine and a
// descriptor only for the connections it handshakes; the others wait in the kernel backlog. Each
// silent client is closed when its handshake times out, and an honest client is accepted after.
func TestSilentClientsWaitInBacklog(t *testing.T) {
	f := newFixture(t)
	const silent, capacity = 8, 2
	const timeout = time.Second
	sc := f.b.Config(t, f.a)
	sc.MaxConcurrentHandshakes = capacity
	sc.HandshakeTimeout = timeout
	ln := listen(t, sc)

	fdsBefore := openDescriptors(t)
	start := time.Now()
	clients := make([]net.Conn, 0, silent)
	for range silent {
		c, err := net.Dial("tcp", ln.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = c.Close() })
		clients = append(clients, c)
	}
	// Give the listener time to accept whatever it is going to accept, well within the timeout.
	time.Sleep(timeout / 3)
	if n := listenerHandlers(); n > capacity {
		t.Fatalf("listener runs %d connection goroutines for %d silent clients, cap %d", n, silent, capacity)
	}
	// The process holds one descriptor per client end, plus one per connection the listener
	// accepted; allow one more for anything else the runtime opens meanwhile.
	if extra := openDescriptors(t) - fdsBefore - silent; extra > capacity+1 {
		t.Fatalf("listener holds %d descriptors for %d silent clients, cap %d", extra, silent, capacity)
	}

	// Every silent client is closed once its handshake times out: they are handshaken cap at a
	// time, so the last batch ends after silent/cap timeouts.
	drained := time.Duration(silent/capacity) * timeout
	for i, c := range clients {
		_ = c.SetReadDeadline(start.Add(drained + 3*time.Second))
		if _, err := c.Read(make([]byte, 1)); err == nil {
			t.Fatalf("silent client %d received data", i)
		} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
			t.Fatalf("silent client %d still open after %v", i, time.Since(start))
		}
	}
	if d := time.Since(start); d < timeout {
		t.Fatalf("silent clients closed after %v, before the handshake timeout %v", d, timeout)
	}

	// The refusals of the silent clients are reported first; then the honest client's channel.
	cc := f.a.Config(t, f.b)
	cc.HandshakeTimeout = 20 * time.Second
	type dialed struct {
		c   *atls.Conn
		err error
	}
	dc := make(chan dialed, 1)
	go func() {
		c, err := dial(t, ln.Addr().String(), cc)
		dc <- dialed{c, err}
	}()
	refusals := 0
	for {
		a := <-acceptOne(ln, 20*time.Second)
		if a.err != nil {
			if !errors.Is(a.err, atls.ErrHandshakeTimeout) {
				t.Fatalf("silent client refused with %v, want a handshake timeout", a.err)
			}
			refusals++
			if refusals > silent {
				t.Fatalf("more refusals than silent clients: %v", a.err)
			}
			continue
		}
		defer func() { _ = a.conn.Close() }()
		break
	}
	d := <-dc
	if d.err != nil {
		t.Fatalf("honest client: %v", d.err)
	}
	_ = d.c.Close()
	if refusals != silent {
		t.Fatalf("%d refusals for %d silent clients", refusals, silent)
	}
}
