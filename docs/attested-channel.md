# Attested channel control

The zones talk to each other only over a mutually attested TLS 1.3 channel (ZT-28 to ZT-35). The
Go package `internal/atls` is the one place that establishes such a channel. It wraps the
Fraunhofer AISEC CMC attested-TLS library and exposes only the demonstrator's own types.

!!! note "Status: candidate contract for IF-07"
    This page is the candidate for interface **IF-07 Attested channel control** in the
    [interface registry](api-docs.md). The interface is drafted and in use by the spike. It is
    frozen once the session-loss scenarios have confirmed the error surfaces. After that, changes
    to it are deliberate and versioned.

## Pinned library

| | |
|---|---|
| Library | `github.com/Fraunhofer-AISEC/cmc`, **v0.9.15** (commit `6754d3c`), unmodified upstream, no `replace` |
| Only importer | `internal/atls` and its sub-packages. A `depguard` rule in CI fails the build for any other importer ([CI/CD](ci-cd.md)) |
| Attester | one `cmcd` per zone, reached over gRPC at `Config.CmcdAddr` |
| Test-only attester | the in-process CMC (`libapi`), reachable only from `internal/atls/atlstest` |
| Handshake messages | JSON; attestation reports as the `cmcd` produces them (CBOR over gRPC) |
| Channel binding | RFC 9266 TLS exporter, label `EXPORTER-Channel-Binding`, 32 bytes. Report nonce = `sha256(exporter ‖ prover's TLS leaf certificate)` |

## Interface

```go
package atls

type Config struct {
    TLS                     *tls.Config    // exactly one static certificate + zone trust anchors
    CmcdAddr                string         // this zone's cmcd, host:port (gRPC)
    Policies                []byte         // optional attestation policies for the verifier
    ExpectedPeerIdentity    string         // URI SAN if it contains "://", DNS SAN otherwise
    HandshakeTimeout        time.Duration  // default 10 s
    ChannelLifetime         time.Duration  // default 15 min
    MaxConcurrentHandshakes int            // default 8
    PeerVerifier            PeerVerifier   // optional veto after attestation
}

func Dial(ctx context.Context, addr string, cfg Config) (*Conn, error)
func Listen(addr string, cfg Config) (*Listener, error)

func (l *Listener) Accept(ctx context.Context) (*Conn, error) // refusals come back as errors; call again
func (l *Listener) Addr() net.Addr
func (l *Listener) Close() error

type Conn struct{ net.Conn /* … */ }
func (c *Conn) Binding() []byte                    // RFC 9266 exporter, same on both ends
func (c *Conn) Peer() PeerAttestation
func (c *Conn) ConnectionState() tls.ConnectionState

type PeerAttestation struct {
    Verdict          Verdict        // always VerdictSuccess on a returned connection
    PeerID           string         // hex SHA-256 of the peer's TLS leaf certificate
    Measurements     []Measurement  // verified measurements of the peer's evidence
    AttestedAt       time.Time      // when this end received the verification result
    EvidenceNotAfter time.Time      // validity end of the peer's evidence (zero if none stated)
    ValidUntil       time.Time      // min(AttestedAt + ChannelLifetime, EvidenceNotAfter)
}

type PeerVerifier interface {
    VerifyPeer(ctx context.Context, peer PeerAttestation) error
}
```

`*atls.Error` carries every refusal: `Kind` (the sentinel), `Reason` (words) and `Err` (the
cause). Match refusals with `errors.Is(err, atls.ErrX)`.

## What a returned channel guarantees (fail closed)

`Dial` and `Accept` return a connection only when **all** of the following hold. Any other outcome
closes the connection and returns a refusal.

1. **TLS 1.3 with mutual certificate authentication.** This holds whatever the caller's `tls.Config`
   allows: the wrapper forces TLS 1.3 as the minimum and requires a client certificate. Key exchange
   is limited to NIST curves, with hybrid ML-KEM preferred. Session resumption is off, so every
   channel is attested afresh.
2. **The peer's certificate is trusted and names the expected peer.** Its chain ends at the zone
   trust anchors, it carries `ExpectedPeerIdentity`, and its key is ECDSA P-256/P-384 or RSA with
   at least 4096 bits (ZT-50). The peer is identified by `ExpectedPeerIdentity`, not by the host
   name it was dialled at.
3. **Mutual attestation completed without error.** The attestation mode is always mutual; a peer
   that asks for another mode is refused.
4. **Exactly one attestation result exists for this connection, and its verdict is `success`.** A
   `warn` verdict is a refusal. A missing result means not attested. The result must belong to the
   certificate of this connection's peer.
5. **The peer's evidence is still valid** at the moment the connection is returned.
6. **The `PeerVerifier`, if configured, accepted the peer.** Without a verifier, the decision rests
   on points 1 to 5.

A returned connection has no read or write deadline left over from the handshake.

## Refusals

Each refusal matches exactly one sentinel and states its reason in words.

| Sentinel | Meaning | Decided from |
|---|---|---|
| `ErrNotAttested` | The peer's attestation did not verify as `success`: failed verification, `warn`, no result, a result for another peer, or the peer reported that it could not verify this end | wrapper verdict rules; CMC result; CMC error text |
| `ErrBindingMismatch` | The peer's report is not bound to this TLS session (for example relayed from another session) | CMC result: freshness check failed (error code `Freshness`) |
| `ErrEvidenceExpired` | The peer's evidence is past its validity | CMC result: metadata validity check `Expired`; wrapper check at return time |
| `ErrIdentityMismatch` | The peer's certificate is untrusted, lacks the expected identity or uses a key outside the crypto baseline; or the peer refused this end's certificate | wrapper TLS verification; TLS alert text |
| `ErrPlainTLS` | The peer does not speak attested TLS 1.3: plain TLS, TLS 1.2 or older, a malformed first attestation message, or a peer that left without completing the attestation exchange | TLS error text; CMC error text |
| `ErrAttestModeMismatch` | The peer requested an attestation mode other than mutual | CMC error text |
| `ErrAttesterUnavailable` | This zone's `cmcd` could not be reached or failed | CMC error text (gRPC / in-process backend) |
| `ErrHandshakeTimeout` | The handshake did not end within the caller's deadline or `HandshakeTimeout`, or no handshake slot became free in time | wrapper deadline; `i/o timeout` from CMC |
| `ErrPeerRejected` | The `PeerVerifier` refused the attested peer. Its error is wrapped and stays inspectable | wrapper |
| `ErrPeerUnreachable` | No TCP connection to the peer. This is a transport failure, not a refusal | dial error text |
| `ErrConfig` | Invalid configuration; no connection was attempted | wrapper validation |

The classifier checks its sources in this order: the wrapper's own deadline, its identity check,
the typed error codes of this connection's attestation result, then the text of CMC's error. CMC
reports errors as plain text. Every text pattern the classifier relies on is pinned by a test
against the CMC v0.9.15 source. An upgrade that rewords an error therefore fails the build instead
of silently changing a refusal. Text that CMC relays from the peer never counts as a local
attester, TLS or timeout failure. No CMC error type leaves the wrapper; CMC causes are reduced to
their text.

## Lifetime

`ValidUntil` is the earlier of `AttestedAt + ChannelLifetime` and the validity end of the peer's
evidence. TLS 1.3 does not renegotiate, so evidence never refreshes on a live channel. The owner of
the channel must re-establish it before `ValidUntil`. The default lifetime of 15 minutes matches
the channel rotation.

The evidence validity end is the earliest of:

- the `Validity.NotAfter` of the peer's signed metadata (image description, manifests, company
  description);
- the certificates that signed that metadata;
- certificates that signed the evidence itself.

sw-driver evidence is signed with a bare key and has no certificate.

## Concurrency and timeouts

- A listener handshakes each incoming connection in its own goroutine, so one slow peer does not
  delay the others.
- At most `MaxConcurrentHandshakes` handshakes run at once per listener, and at most that many
  across all `Dial` calls of the process. A connection waits for a slot up to the handshake
  timeout and is then refused with `ErrHandshakeTimeout`.
- `Dial` returns within the context deadline or `HandshakeTimeout`, whichever is sooner. If CMC is
  still blocked in the peer exchange at that point, the connection it returns later is closed. Its
  goroutine keeps its handshake slot until CMC gives up, so stalled peers cannot exceed the cap.
- The listener closes a connection whose handshake outlives `HandshakeTimeout`.

## Attester selection and builds

Production code sets `CmcdAddr` and attests through the zone's `cmcd`. The in-process CMC cannot be
selected from production code:

- the Config field that selects it is unexported;
- the hook that sets it lives in a package Go's internal-package rule restricts to
  `internal/atls/...`;
- `internal/atls/atlstest` panics outside a test binary, and `depguard` refuses it in non-test
  files.

CMC's default build links every TEE driver, and the SGX driver needs cgo. A binary built with
`CGO_ENABLED=0` must use the build tags `nodefaults,grpc`. They keep only the gRPC attester and
drop the in-process backend and the TEE drivers from the binary.

## Session loss: what each end observes

The session-loss proof (`scripts/atls-probe/prove-c3.sh`) runs two probe processes over this
interface, each with the real `cmcd` of its zone, and takes one thing away at a time. Its findings
are in
[reconnect-findings.md](evidences/cmc-atls-channel-binding/criterion-3-session-loss/reconnect-findings.md).
The run recorded there is local (one machine, loopback); a run on the target cluster is pending.

| What happens | What the surviving end gets | Refusal sentinel |
|---|---|---|
| The peer process is killed while the channel is open | The next `Read` returns `io.EOF` within milliseconds | none — a transport error |
| This zone's `cmcd` is killed while the channel is open | Nothing. The channel keeps working; the attester is needed only during a handshake | none |
| A handshake while this zone's `cmcd` is down, or dies during the handshake | The handshake is refused within milliseconds | `ErrAttesterUnavailable` |
| A handshake while the *peer's* `cmcd` is down, or dies during the handshake | The handshake is refused: "the peer left without completing the attestation exchange" | `ErrPlainTLS` |
| The peer process is frozen (half-open channel) | No error within 15 s. Writes keep succeeding, reads wait. Only the missing heartbeats of the application show it. After the peer runs again the channel continues | none |
| A new handshake towards a frozen peer | The handshake is refused after `HandshakeTimeout` | `ErrHandshakeTimeout` |
| A new handshake towards a peer that is down | The handshake is refused at once | `ErrPeerUnreachable` |

In every scenario a new channel could be opened as soon as the missing process was back.

### Error surfaces the sentinels do not express

These are input for the freeze of this interface. The interface is unchanged by them so far.

1. **Loss of an established channel has no sentinel.** All sentinels describe a refused
   handshake. After `Dial` or `Accept` has returned, `Read` and `Write` return the errors of
   `crypto/tls` and `net` as they are. A peer that was killed and a peer that closed the channel in
   an orderly way both surface as `io.EOF`: Go reports an end of stream at a record boundary as
   `io.EOF` whether or not the peer sent its closing alert. The owner of the channel cannot tell a
   crash from a close by the error value.
2. **A half-open channel is not detected.** The wrapper sets no deadline on a returned connection
   and has no heartbeat of its own. A frozen peer is invisible at this interface until the owner's
   own traffic shows it. The operating system's TCP keep-alive does not show it either: the kernel
   of a frozen process still acknowledges. Detecting it needs an application heartbeat with a read
   deadline, owned either by the wrapper or by its caller; the freeze must say which. A network
   partition, where the peer's kernel is unreachable too, was not part of this run.
3. **A peer whose attester is unavailable is reported as `ErrPlainTLS`.** The end whose `cmcd` is
   down gets the exact `ErrAttesterUnavailable`. The other end gets `ErrPlainTLS`, which reads as
   "this peer does not speak attested TLS" although the peer does and merely could not attest. CMC
   hides the peer's cause (limitation N7 below), so the wrapper cannot name it. The sentinel's
   meaning has to be widened in its description, or a separate sentinel introduced for "the peer
   aborted the attestation exchange".
4. **Losing the local `cmcd` is silent until the next handshake.** An open channel gives no sign
   of it. With a channel rotation every 15 minutes, a dead `cmcd` is first noticed when the
   rotation fails with `ErrAttesterUnavailable`, while the old channel is still usable until its
   `ValidUntil`. Noticing it earlier is a health check on `cmcd`, outside this interface.
5. **A refusal returned by `Accept` does not identify the peer.** `*atls.Error` carries the
   sentinel, the reason and the cause, but no remote address. A listener can attribute a refusal
   to a peer only through the text of the cause.

## Known CMC v0.9.15 limitations

The wrapper is built around the following behaviour of CMC v0.9.15. Findings marked *tested* are
pinned by regression tests in `internal/atls`, which drive CMC directly. If CMC changes, those tests
fail and the entry must be revisited.

| # | Behaviour | Effect without the wrapper | Mitigation in the wrapper | Residual |
|---|---|---|---|---|
| 1 | The listener sets a 10 s read/write deadline for the handshake and never clears it (*tested*) | Accepted connections fail their first read after 10 s | Deadline cleared after a successful handshake | none |
| 2 | The client bounds only TCP connect and TLS; the attestation phase has no deadline (*tested*) | `Dial` blocks indefinitely against a silent server | `Dial` bounded by context and `HandshakeTimeout` | the abandoned goroutine and socket live until the peer or keep-alive ends them; bounded by the handshake cap |
| 3 | `Accept` runs TLS and attestation inline | One slow client blocks all other accepts | One goroutine per connection | none |
| 4 | The result callback fires inside verification, on failure too, and before `Accept`/`Dial` return; `warn` counts as success; some failure paths produce no callback (*tested*) | Callers may trust a result of a failed handshake, or a `warn` | A result is trusted only after a handshake that returned without error; `warn` and missing results are refusals; one callback per connection | none |
| N1 | When the peer answers with an error, one goroutine per handshake blocks forever (*tested*) | Goroutine growth under repeated failing handshakes | None in the wrapper: the goroutine outlives the handshake, so the handshake cap does not bound it. Mutual TLS limits who can reach this phase to holders of a zone certificate | leaked goroutines accumulate, one per such handshake; upstream fix needed |
| N2 | Resource-exhaustion class issue in the attestation message framing, triggerable by a peer | Memory pressure from a single connection | Mutual TLS gates the phase; the handshake cap bounds concurrency; pod memory limits | not fixable in the wrapper (CMC requires the concrete TLS connection type). Details are withheld until coordinated disclosure with the contracting authority |
| N3 | Channel binding reads only `tls.Config.Certificates[0]` | A dynamic or second certificate breaks the binding | Exactly one static certificate required; certificate callbacks refused (`ErrConfig`) | none |
| N4 | The in-process backend re-initialises process-global TEE drivers on every call; the sw driver also writes state per report | Data races; with two zones in one process, a report can mix one zone's key and the other's signature | In-process backend is test-only. Test fixtures share one sw key across zones and serialise report generation; concurrency tests use the gRPC path | a `cmcd` serving concurrent sw-driver reports races internally. This concerns mock evidence only |
| N5 | On the peer-error path, the response and the handshake-complete message are written concurrently, and their frames can interleave | The peer may fail to parse and stall until its deadline | Wrapper deadlines bound this side | upstream fix needed |
| N6 | Attestation messages carry no type. When one side fails before sending its request, the other side parses its handshake-complete message as the request | The protocol desynchronises until CMC's 10 s deadline | `HandshakeTimeout` bounds the listener side | none beyond the timeout |
| N7 | CMC returns the real handshake error only when the handshake-complete exchange succeeds | A peer that leaves early hides the cause (for example a plain-TLS peer) | Complete-stage failure without an attestation result on this side is reported as `ErrPlainTLS`; with a result, as `ErrNotAttested` | the precise cause is lost for peers that leave early |
| N8 | The client does not close the TLS connection when attestation fails (code reading) | Socket held until garbage collection | none possible; the peer closes its end | upstream fix needed |
| N9 | A failed TLS dial dereferences the certificate's parsed leaf without a nil check (code reading) | A certificate without a parsed leaf panics the dialing goroutine | The wrapper always sets the parsed leaf | none |

Findings 1 to 4 and N1 were first established by reading the code; the regression tests confirmed
all five. N4 to N7 were found while testing the wrapper.
