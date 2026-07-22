package main

import (
	"os/exec"
	"strings"
	"testing"
)

func TestShellQuoteRoundTrips(t *testing.T) {
	cases := []string{
		"plain",
		"has space",
		"single'quote",
		"multiple''quotes''here",
		"; touch /tmp/pwned",
		"$(rm -rf /)",
		"`backticks`",
		"",
	}
	for _, in := range cases {
		t.Run(in, func(t *testing.T) {
			quoted := shellQuote(in)
			// Round-trip through a real POSIX shell (sh, not bash) and
			// confirm it reproduces exactly the original string via a
			// single argv element — this is the actual threat model
			// (eos runs command: through /bin/sh -c), not just "looks
			// quoted".
			out, err := exec.Command("sh", "-c", "printf '%s' "+quoted).Output()
			if err != nil {
				t.Fatalf("sh -c failed for input %q: %v", in, err)
			}
			if got := string(out); got != in {
				t.Fatalf("round-trip mismatch: input %q, quoted %q, got back %q", in, quoted, got)
			}
		})
	}
}

func TestShellQuoteBlocksInjection(t *testing.T) {
	evil := "x; touch /tmp/tunnel_setup_injection_test_marker"
	quoted := shellQuote(evil)
	cmd := "echo start " + quoted + " end"
	out, err := exec.Command("sh", "-c", cmd).Output()
	if err != nil {
		t.Fatalf("sh -c failed: %v", err)
	}
	if !strings.Contains(string(out), evil) {
		t.Fatalf("expected the evil string to appear literally in output, got %q", string(out))
	}
	if _, err := exec.Command("test", "-f", "/tmp/tunnel_setup_injection_test_marker").Output(); err == nil {
		t.Fatal("injection succeeded — marker file was created")
	}
}

// TestAssumeYesAloneDoesNotSkipFingerprintCheck guards against eos-plugins#7
// reappearing: -yes alone must NOT bypass host-key fingerprint verification
// (the tunnel's only defense against a MITM'd first connection) — only the
// explicit, separate -skip-fingerprint-check flag may do that.
func TestAssumeYesAloneDoesNotSkipFingerprintCheck(t *testing.T) {
	cases := []struct {
		name                 string
		assumeYes            bool
		skipFingerprintCheck bool
		wantSkip             bool
	}{
		{"neither flag", false, false, false},
		{"yes alone", true, false, false},
		{"skip-fingerprint-check alone", false, true, true},
		{"both flags", true, true, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg := config{assumeYes: c.assumeYes, skipFingerprintCheck: c.skipFingerprintCheck}
			if got := shouldSkipFingerprintPrompt(cfg); got != c.wantSkip {
				t.Errorf("shouldSkipFingerprintPrompt(assumeYes=%v, skipFingerprintCheck=%v) = %v, want %v",
					c.assumeYes, c.skipFingerprintCheck, got, c.wantSkip)
			}
		})
	}
}
