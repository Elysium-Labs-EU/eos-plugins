// Command tunnel-setup sets up an SSH tunnel so eos-sink-otlp can reach an
// OTLP collector on a different host while only ever dialing 127.0.0.1.
// Run this on the side that will INITIATE the SSH connection:
//
//	--direction local   (default): run on the eos/service host, tunnels out
//	                      to a collector on another VPS (-L).
//	--direction reverse : run on the collector host (e.g. your home
//	                      machine, behind NAT), dials out to the VPS
//	                      running eos so the VPS's loopback reaches back
//	                      to this machine's collector (-R).
//
// The tunnel itself is registered and supervised as an eos service (same
// `eos run -f` this host already uses for everything else) rather than a
// hand-rolled systemd unit or launchd plist — that's what makes this
// identical on Linux, macOS, or anywhere else eos runs, and it means no
// root/dedicated system account is needed either.
//
// This orchestrates existing trusted tools (ssh-keygen, ssh-keyscan, ssh,
// eos) via argv-safe exec.Command calls — it does not reimplement any SSH
// protocol or crypto itself.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type config struct {
	direction      string
	remoteHost     string
	remoteUser     string
	remoteSSHPort  string
	otlpPort       string
	serviceName    string
	assumeYes      bool
}

func main() {
	cfg := parseFlags()
	if err := run(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func parseFlags() config {
	var cfg config
	flag.StringVar(&cfg.direction, "direction", "local", "local (-L, dial out to a remote collector) or reverse (-R, dial out to a remote eos host)")
	flag.StringVar(&cfg.remoteHost, "remote-host", "", "hostname/IP of the other side of the tunnel (required)")
	flag.StringVar(&cfg.remoteUser, "remote-user", "otlp-tunnel", "SSH login user for the tunnel on the far side")
	flag.StringVar(&cfg.remoteSSHPort, "remote-ssh-port", "22", "SSH port on the far side")
	flag.StringVar(&cfg.otlpPort, "port", "4317", "OTLP port forwarded on both ends")
	flag.StringVar(&cfg.serviceName, "service-name", "eos-otlp-tunnel", "eos service name for the tunnel")
	flag.BoolVar(&cfg.assumeYes, "yes", false, "don't pause for confirmation before continuing past the \"add this key\" step")
	flag.BoolVar(&cfg.assumeYes, "y", false, "shorthand for -yes")
	flag.Parse()
	return cfg
}

func run(cfg config) error {
	if _, err := exec.LookPath("eos"); err != nil {
		return fmt.Errorf("eos is not on PATH — install it first: https://github.com/Elysium-Labs-EU/eos")
	}
	if cfg.remoteHost == "" {
		return fmt.Errorf("-remote-host is required")
	}
	if cfg.direction != "local" && cfg.direction != "reverse" {
		return fmt.Errorf("-direction must be 'local' or 'reverse'")
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("resolving home directory: %w", err)
	}
	stateDir := filepath.Join(home, ".eos-otlp-tunnel", cfg.serviceName)
	keyPath := filepath.Join(stateDir, "otlp_tunnel_key")
	knownHosts := filepath.Join(stateDir, "known_hosts")
	serviceYAML := filepath.Join(stateDir, "service.yaml")

	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return fmt.Errorf("creating state dir: %w", err)
	}

	fmt.Println("== 1/6: tunnel keypair ==")
	if err := ensureKeypair(keyPath); err != nil {
		return err
	}
	pubKey, err := os.ReadFile(keyPath + ".pub")
	if err != nil {
		return fmt.Errorf("reading generated public key: %w", err)
	}

	fmt.Println("\n== 2/6: add this to the OTHER host ==")
	restriction := restrictionLine(cfg)
	fmt.Printf("On %s, as the %s user, append to ~%s/.ssh/authorized_keys:\n\n", cfg.remoteHost, cfg.remoteUser, cfg.remoteUser)
	fmt.Printf("  %s %s", restriction, string(pubKey))
	fmt.Println("(that user should exist with a non-interactive shell — the exact command depends on that")
	fmt.Println(" host's OS, e.g. Linux: 'useradd -r -m -s /usr/sbin/nologin " + cfg.remoteUser + "'; adjust for macOS/other.")
	if cfg.direction == "local" {
		fmt.Printf(" The collector on that side must itself bind only 127.0.0.1:%s, never 0.0.0.0.)\n", cfg.otlpPort)
	} else {
		fmt.Println(")")
	}

	if !cfg.assumeYes {
		if err := pause("Press enter once that's done (Ctrl-C to abort)... "); err != nil {
			return err
		}
	}

	fmt.Println("\n== 3/6: pin the remote host key ==")
	if err := pinHostKey(cfg, knownHosts); err != nil {
		return err
	}

	fmt.Println("\n== 4/6: register as an eos service ==")
	if err := writeServiceYAML(cfg, serviceYAML, keyPath, knownHosts); err != nil {
		return err
	}
	// --once: re-running this against an already-healthy tunnel must not
	// bounce it (eos run without --once restarts an already-running
	// service, dropping the connection for no reason on a second run).
	if err := runInteractive("eos", "run", "-f", serviceYAML, "--once"); err != nil {
		return fmt.Errorf("eos run failed: %w", err)
	}

	fmt.Println("\n== 5/6: keep eos itself running across crashes/reboots ==")
	fmt.Println("This tunnel (and this host's telemetry, since it rides the same tunnel) is only as")
	fmt.Println("durable as the eos daemon supervising it. Without boot-persistence, an eos crash")
	fmt.Println("silently takes the tunnel down with no supervisor left to bring it back.")
	// eos system startup prompts interactively (y/n) with no --yes flag of
	// its own. In -yes/non-interactive runs there's no stdin to answer it
	// with, so don't attempt it — just point at the command. Otherwise
	// pass the real terminal through so a human can answer the prompt
	// live (capturing output instead leaves stdin unconnected and the
	// prompt hits EOF immediately — confirmed the hard way in testing).
	if cfg.assumeYes {
		fmt.Println("Run 'eos system startup' yourself when ready (skipped here — it prompts interactively).")
	} else if err := runInteractive("eos", "system", "startup"); err != nil {
		fmt.Fprintln(os.Stderr, "note: 'eos system startup' did not complete — see above.")
	}
	fmt.Println("Separately: eos's own health monitor gives up restarting a service after")
	fmt.Println("health.maxRestart consecutive failures (default 10, in ~/.eos/config.yaml) — a")
	fmt.Println("genuinely prolonged outage on the far side could exhaust that before it resolves,")
	fmt.Println("leaving this in a 'failed (stale)' state until 'eos run " + cfg.serviceName + "' is run manually.")
	fmt.Println("Regardless of the above: set an absence alert on the collector side (e.g. \"no data from")
	fmt.Println("service.name=<your service> in N minutes\") — that's the reliable way to notice this pipe")
	fmt.Println("went dark, since a dead pipe can't be counted on to report its own death.")

	fmt.Println("\n== 6/6: self-test ==")
	return selfTest(cfg)
}

// runInteractive runs a command with the real terminal wired through
// (stdin/stdout/stderr), for subcommands that may prompt interactively.
func runInteractive(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func ensureKeypair(keyPath string) error {
	if _, err := os.Stat(keyPath); err == nil {
		fmt.Printf("%s already exists, reusing\n", keyPath)
		return nil
	}
	host, _ := os.Hostname()
	cmd := exec.Command("ssh-keygen", "-t", "ed25519", "-f", keyPath, "-N", "", "-C", "eos-otlp-tunnel@"+host, "-q")
	if out, err := cmd.CombinedOutput(); err != nil {
		fmt.Print(string(out))
		return fmt.Errorf("generating keypair: %w", err)
	}
	fmt.Printf("generated %s\n", keyPath)
	return nil
}

func restrictionLine(cfg config) string {
	// 'restrict' alone does NOT let 'permitopen'/'permitlisten' re-enable
	// forwarding — needs the explicit 'port-forwarding' flag too, or sshd
	// silently refuses every channel-open while still reporting the local
	// listener as up. Confirmed on OpenSSH 10.2 despite sshd(8)'s own
	// example implying permitopen is sufficient on its own.
	if cfg.direction == "local" {
		return fmt.Sprintf(`restrict,port-forwarding,permitopen="127.0.0.1:%s"`, cfg.otlpPort)
	}
	return fmt.Sprintf(`restrict,port-forwarding,permitlisten="127.0.0.1:%s"`, cfg.otlpPort)
}

func pinHostKey(cfg config, knownHosts string) error {
	scan, err := exec.Command("ssh-keyscan", "-t", "ed25519", "-p", cfg.remoteSSHPort, cfg.remoteHost).Output()
	if err != nil || len(strings.TrimSpace(string(scan))) == 0 {
		return fmt.Errorf("could not reach %s:%s to scan its host key", cfg.remoteHost, cfg.remoteSSHPort)
	}
	scanLine := strings.TrimSpace(string(scan))

	fields := strings.SplitN(scanLine, " ", 2)
	if len(fields) != 2 {
		return fmt.Errorf("unexpected ssh-keyscan output: %q", scanLine)
	}
	fingerprint, err := fingerprintOf(fields[1])
	if err != nil {
		return err
	}
	fmt.Printf("Host key for %s: %s\n", cfg.remoteHost, fingerprint)
	fmt.Println("Verify this out-of-band (your VPS provider's console/API, or a channel you already trust) before continuing.")
	if !cfg.assumeYes {
		answer, err := prompt("Matches? [y/N] ")
		if err != nil {
			return err
		}
		if answer != "y" && answer != "Y" {
			return fmt.Errorf("aborting — fingerprint not confirmed")
		}
	}

	f, err := os.OpenFile(knownHosts, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("opening known_hosts: %w", err)
	}
	if _, err := fmt.Fprintln(f, scanLine); err != nil {
		_ = f.Close()
		return fmt.Errorf("writing known_hosts: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("closing known_hosts: %w", err)
	}
	return nil
}

func fingerprintOf(keyLine string) (string, error) {
	cmd := exec.Command("ssh-keygen", "-lf", "/dev/stdin")
	cmd.Stdin = strings.NewReader(keyLine)
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("computing host key fingerprint: %w", err)
	}
	return strings.TrimSpace(string(out)), nil
}

func writeServiceYAML(cfg config, serviceYAML, keyPath, knownHosts string) error {
	forwardFlag := fmt.Sprintf("127.0.0.1:%s:127.0.0.1:%s", cfg.otlpPort, cfg.otlpPort)
	args := []string{
		"ssh", "-N",
		"-p", cfg.remoteSSHPort,
		"-o", "ExitOnForwardFailure=yes",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
		"-o", "StrictHostKeyChecking=yes",
		"-o", "BatchMode=yes",
		"-o", "UserKnownHostsFile=" + knownHosts,
		"-i", keyPath,
	}
	if cfg.direction == "local" {
		args = append(args, "-L", forwardFlag)
	} else {
		args = append(args, "-R", forwardFlag)
	}
	args = append(args, cfg.remoteUser+"@"+cfg.remoteHost)

	// eos runs a service's `command:` via `/bin/sh -c "$command"` — a single
	// flat string, not an argv array — so every dynamic piece still needs
	// POSIX-sh-safe quoting here, same requirement as it would be from a
	// shell script. shellQuote is unit-tested (see main_test.go) precisely
	// because this exact class of bug (unquoted interpolation into a string
	// later re-parsed by a shell) is a real command-injection risk, not
	// just a style nit — confirmed the hard way in the previous version of
	// this tool.
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = shellQuote(a)
	}
	command := strings.Join(quoted, " ")

	content := fmt.Sprintf("name: %q\ncommand: %q\n", cfg.serviceName, command)
	if err := os.WriteFile(serviceYAML, []byte(content), 0o600); err != nil {
		return fmt.Errorf("writing service.yaml: %w", err)
	}
	return nil
}

// shellQuote wraps s in single quotes, safe to embed in a string a POSIX
// shell will later parse as one token, regardless of what s contains.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func selfTest(cfg config) error {
	if cfg.direction != "local" {
		fmt.Printf("Tunnel started. This host can't self-test the far end (that's on %s).\n", cfg.remoteHost)
		fmt.Printf("On %s, verify with:\n", cfg.remoteHost)
		fmt.Printf("  nc -z 127.0.0.1 %s && echo OK || echo FAIL\n", cfg.otlpPort)
		fmt.Printf("eos-sink-otlp on %s can then use address: \"127.0.0.1:%s\", insecure: true\n", cfg.remoteHost, cfg.otlpPort)
		return nil
	}

	addr := net.JoinHostPort("127.0.0.1", cfg.otlpPort)
	// eos run returns as soon as the process forks — well before ssh has
	// finished DNS/handshake/auth/forwarding setup, especially on a slow
	// link. Poll instead of trusting a single fixed sleep.
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		conn, err := net.DialTimeout("tcp", addr, 3*time.Second)
		if err == nil {
			_ = conn.Close()
			fmt.Printf("OK: %s reachable locally through the tunnel.\n", addr)
			fmt.Printf("eos-sink-otlp on this host can now use address: %q, insecure: true\n", addr)
			return nil
		}
		lastErr = err
		time.Sleep(1 * time.Second)
	}
	fmt.Fprintf(os.Stderr, "FAILED: could not reach %s through the tunnel: %v\n", addr, lastErr)
	fmt.Fprintf(os.Stderr, "Check: 'eos logs %s', and that the authorized_keys line on %s matches EXACTLY\n", cfg.serviceName, cfg.remoteHost)
	fmt.Fprintln(os.Stderr, "what was printed above (the port-forwarding flag is easy to drop and fails silently —")
	fmt.Fprintln(os.Stderr, "the tunnel process stays up either way).")
	return fmt.Errorf("self-test failed")
}

func pause(msg string) error {
	fmt.Print(msg)
	_, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil {
		return fmt.Errorf("reading confirmation: %w", err)
	}
	return nil
}

func prompt(msg string) (string, error) {
	fmt.Print(msg)
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil {
		return "", fmt.Errorf("reading input: %w", err)
	}
	return strings.TrimSpace(line), nil
}
