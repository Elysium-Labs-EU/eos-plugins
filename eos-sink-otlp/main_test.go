package main

import (
	"strings"
	"testing"

	otellog "go.opentelemetry.io/otel/log"
)

func TestReadNDJSONSurvivesLineOverScannerLimit(t *testing.T) {
	// bufio.Scanner's default token limit is 64KB (bufio.MaxScanTokenSize);
	// a line past that must not stop lines after it from being handled.
	oversized := strings.Repeat("x", 70*1024)
	input := "first\n" + oversized + "\nlast"

	var got []string
	if err := readNDJSON(strings.NewReader(input), func(line string) {
		got = append(got, line)
	}); err != nil {
		t.Fatalf("readNDJSON returned error: %v", err)
	}

	if len(got) != 3 {
		t.Fatalf("got %d lines, want 3", len(got))
	}
	if got[0] != "first" || got[2] != "last" {
		t.Fatalf("got[0]=%q got[2]=%q, want %q and %q", got[0], got[2], "first", "last")
	}
	if len(got[1]) != len(oversized) {
		t.Fatalf("oversized line length = %d, want %d (line was truncated or dropped)", len(got[1]), len(oversized))
	}
}

func TestReadNDJSONSkipsBlankLines(t *testing.T) {
	var got []string
	err := readNDJSON(strings.NewReader("a\n\nb\n"), func(line string) {
		got = append(got, line)
	})
	if err != nil {
		t.Fatalf("readNDJSON returned error: %v", err)
	}
	if len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("got %v, want [a b]", got)
	}
}

func TestParseEndpoint(t *testing.T) {
	cases := []struct {
		name         string
		address      string
		wantEndpoint string
		force        bool
		wantInsecure bool
	}{
		{"https keeps tls", "https://otel:4317", "otel:4317", false, false},
		{"https force insecure wins", "https://otel:4317", "otel:4317", true, true},
		{"http is insecure", "http://otel:4317", "otel:4317", false, true},
		{"bare host is insecure", "otel:4317", "otel:4317", false, true},
		{"bare host force insecure noop", "otel:4317", "otel:4317", true, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ep, insec := parseEndpoint(c.address, c.force)
			if ep != c.wantEndpoint || insec != c.wantInsecure {
				t.Fatalf("parseEndpoint(%q, %v) = (%q, %v), want (%q, %v)",
					c.address, c.force, ep, insec, c.wantEndpoint, c.wantInsecure)
			}
		})
	}
}

func TestSeverityFor(t *testing.T) {
	cases := []struct {
		stream string
		want   otellog.Severity
	}{
		{"stderr", otellog.SeverityError},
		{"stdout", otellog.SeverityInfo},
		{"", otellog.SeverityInfo},
		{"other", otellog.SeverityInfo},
	}
	for _, c := range cases {
		if got := severityFor(c.stream); got != c.want {
			t.Errorf("severityFor(%q) = %v, want %v", c.stream, got, c.want)
		}
	}
}
