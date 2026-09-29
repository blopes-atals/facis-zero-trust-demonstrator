package atls

import (
	"errors"
	"strings"
)

// Refusal sentinels. Every refused channel returns an *Error whose Kind is exactly one of these,
// so callers match with errors.Is. The Reason of the *Error states the cause in words.
var (
	// ErrNotAttested: the peer's attestation did not verify with verdict success. Covers a failed
	// verification, a warn verdict, a missing result, and a peer that reports it could not verify
	// this end.
	ErrNotAttested = errors.New("atls: peer not attested")

	// ErrBindingMismatch: the peer's attestation report is not bound to this TLS session (for
	// example a report relayed from another session).
	ErrBindingMismatch = errors.New("atls: attestation report not bound to this TLS session")

	// ErrEvidenceExpired: the peer's evidence is past its validity.
	ErrEvidenceExpired = errors.New("atls: peer evidence expired")

	// ErrIdentityMismatch: the peer's certificate does not chain to the zone trust anchors, does
	// not carry the expected identity, uses a key algorithm outside the crypto baseline, or the
	// peer refused this end's certificate.
	ErrIdentityMismatch = errors.New("atls: peer certificate identity rejected")

	// ErrPlainTLS: the peer does not speak attested TLS 1.3 — a plain TLS peer, a peer limited
	// to TLS 1.2 or older, or a peer whose first attestation message is malformed.
	ErrPlainTLS = errors.New("atls: peer does not speak attested TLS 1.3")

	// ErrAttestModeMismatch: the peer requested an attestation mode other than mutual.
	ErrAttestModeMismatch = errors.New("atls: attestation mode mismatch")

	// ErrAttesterUnavailable: this zone's attester (cmcd) could not be reached or failed.
	ErrAttesterUnavailable = errors.New("atls: local attester unavailable")

	// ErrHandshakeTimeout: the handshake did not finish within the caller's deadline or the
	// configured handshake timeout, or no handshake slot became free in time.
	ErrHandshakeTimeout = errors.New("atls: handshake timed out")

	// ErrPeerRejected: the configured PeerVerifier refused the attested peer. The verifier's
	// error is wrapped and remains inspectable with errors.Is and errors.As.
	ErrPeerRejected = errors.New("atls: peer rejected by verifier")

	// ErrPeerUnreachable: no TCP connection to the peer could be opened. This is a transport
	// failure before any TLS or attestation exchange, not a refusal by either side.
	ErrPeerUnreachable = errors.New("atls: peer unreachable")

	// ErrConfig: the Config is invalid; no connection was attempted.
	ErrConfig = errors.New("atls: invalid configuration")
)

// Error is the error type returned for every refusal and configuration error.
type Error struct {
	// Kind is the sentinel the error matches.
	Kind error
	// Reason states the cause in words.
	Reason string
	// Err is the underlying cause, if any. Causes from the attestation library are reduced to
	// their text; a PeerVerifier error and context errors are kept as they are.
	Err error
}

func (e *Error) Error() string {
	var b strings.Builder
	b.WriteString(e.Kind.Error())
	if e.Reason != "" {
		b.WriteString(": ")
		b.WriteString(e.Reason)
	}
	if e.Err != nil {
		b.WriteString(": ")
		b.WriteString(e.Err.Error())
	}
	return b.String()
}

// Unwrap exposes the sentinel and the cause to errors.Is and errors.As.
func (e *Error) Unwrap() []error {
	if e.Err == nil {
		return []error{e.Kind}
	}
	return []error{e.Kind, e.Err}
}

func refuse(kind error, reason string, cause error) *Error {
	return &Error{Kind: kind, Reason: reason, Err: cause}
}

// textCause reduces an error from the attestation library to its text, so no library error type
// leaves the wrapper.
func textCause(err error) error {
	if err == nil {
		return nil
	}
	return errors.New(err.Error())
}
