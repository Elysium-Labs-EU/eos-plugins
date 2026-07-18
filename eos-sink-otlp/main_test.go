package main

import (
	"testing"

	otellog "go.opentelemetry.io/otel/log"
)

func TestParseEndpoint(t *testing.T) {
	cases := []struct {
		name         string
		address      string
		force        bool
		wantEndpoint string
		wantInsecure bool
	}{
		{"https keeps tls", "https://otel:4317", false, "otel:4317", false},
		{"https force insecure wins", "https://otel:4317", true, "otel:4317", true},
		{"http is insecure", "http://otel:4317", false, "otel:4317", true},
		{"bare host is insecure", "otel:4317", false, "otel:4317", true},
		{"bare host force insecure noop", "otel:4317", true, "otel:4317", true},
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
