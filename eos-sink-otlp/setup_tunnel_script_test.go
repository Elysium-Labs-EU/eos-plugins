package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Exercises setup-tunnel.sh's argument parsing and static systemd unit
// content directly (as a subprocess / file read), since the script itself
// requires root and live ssh/systemd to run end-to-end.

func runSetupTunnel(t *testing.T, args ...string) (string, error) {
	t.Helper()
	script, err := filepath.Abs("setup-tunnel.sh")
	if err != nil {
		t.Fatalf("resolve script path: %v", err)
	}
	cmd := exec.Command("bash", append([]string{script}, args...)...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func TestSetupTunnelHelpDocumentsSeparateFingerprintFlag(t *testing.T) {
	out, err := runSetupTunnel(t, "--help")
	if err != nil {
		t.Fatalf("--help exited with error: %v\noutput:\n%s", err, out)
	}
	if !strings.Contains(out, "--skip-fingerprint-check") {
		t.Fatalf("--help output missing --skip-fingerprint-check flag:\n%s", out)
	}
	if !strings.Contains(out, "Does NOT skip") {
		t.Fatalf("--help output does not clarify that --yes leaves fingerprint verification on:\n%s", out)
	}
}

func TestSetupTunnelYesDoesNotImplySkipFingerprintCheck(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("test assumes non-root; running as root would pass the id-check gate and reach real ssh-keyscan/systemd calls")
	}
	// --yes alone must still be accepted as a known flag (it only skips the
	// convenience prompt); it should fail at the root check, not at argument
	// parsing.
	out, err := runSetupTunnel(t, "--remote-host", "example.invalid", "--yes")
	if err == nil {
		t.Fatalf("expected non-zero exit (non-root), got success. output:\n%s", out)
	}
	if !strings.Contains(out, "must run as root") {
		t.Fatalf("expected to fail at the root check (proving --yes still parses), got:\n%s", out)
	}
}

func TestSetupTunnelSkipFingerprintCheckIsRecognizedFlag(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("test assumes non-root; running as root would pass the id-check gate and reach real ssh-keyscan/systemd calls")
	}
	out, err := runSetupTunnel(t, "--remote-host", "example.invalid", "--skip-fingerprint-check")
	if err == nil {
		t.Fatalf("expected non-zero exit (non-root), got success. output:\n%s", out)
	}
	if strings.Contains(out, "unknown argument") {
		t.Fatalf("--skip-fingerprint-check was rejected as an unknown argument:\n%s", out)
	}
	if !strings.Contains(out, "must run as root") {
		t.Fatalf("expected --skip-fingerprint-check to be accepted and fail at the root check instead, got:\n%s", out)
	}
}

func TestSetupTunnelUnknownFlagStillRejected(t *testing.T) {
	out, err := runSetupTunnel(t, "--bogus-flag")
	if err == nil {
		t.Fatalf("expected failure for an unknown flag, got success. output:\n%s", out)
	}
	if !strings.Contains(out, "unknown argument") {
		t.Fatalf("expected an 'unknown argument' error, got:\n%s", out)
	}
}

func TestSetupTunnelSystemdUnitHasBoundedRestartLimit(t *testing.T) {
	data, err := os.ReadFile("setup-tunnel.sh")
	if err != nil {
		t.Fatalf("read setup-tunnel.sh: %v", err)
	}
	src := string(data)
	if strings.Contains(src, "StartLimitIntervalSec=0") {
		t.Fatalf("setup-tunnel.sh disables systemd's restart rate limit (StartLimitIntervalSec=0) -- combined with ExitOnForwardFailure, a misconfigured authorized_keys restriction causes an unbounded ssh reconnect loop against the remote host")
	}
	if !strings.Contains(src, "StartLimitBurst=") {
		t.Fatalf("setup-tunnel.sh's systemd unit sets a nonzero StartLimitIntervalSec but no StartLimitBurst, so restarts are effectively still unbounded within long-lived intervals")
	}
}
