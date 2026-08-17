package main

import (
	"os"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/otel/attribute"
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

// attrs collects a record's attributes into a map so a test can assert one key
// without depending on iteration order.
func attrs(t *testing.T, lr *otellog.Record) map[string]string {
	t.Helper()
	out := make(map[string]string, lr.AttributesLen())
	lr.WalkAttributes(func(kv attribute.KeyValue) bool {
		out[string(kv.Key)] = kv.Value.AsString()
		return true
	})
	return out
}

func TestBuildRecord(t *testing.T) {
	fallback := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	now := func() time.Time { return fallback }

	t.Run("maps body severity and stream attribute", func(t *testing.T) {
		ts := "2026-08-17T05:30:00.123456789Z"
		lr := buildRecord(record{TS: ts, Stream: "stderr", Msg: "disk full"}, now)

		if got := lr.Body().AsString(); got != "disk full" {
			t.Errorf("body = %q, want %q", got, "disk full")
		}
		if got := lr.Severity(); got != otellog.SeverityError {
			t.Errorf("severity = %v, want %v", got, otellog.SeverityError)
		}
		// The attribute is what tells a backend whether a line came from
		// stdout or stderr; dropping it is a silent loss, not a build error.
		if got := attrs(t, &lr)["log.iostream"]; got != "stderr" {
			t.Errorf("log.iostream = %q, want %q", got, "stderr")
		}

		want, err := time.Parse(time.RFC3339Nano, ts)
		if err != nil {
			t.Fatalf("parsing the fixture timestamp: %v", err)
		}
		if !lr.Timestamp().Equal(want) {
			t.Errorf("timestamp = %v, want %v", lr.Timestamp(), want)
		}
		if !lr.ObservedTimestamp().Equal(want) {
			t.Errorf("observed timestamp = %v, want %v", lr.ObservedTimestamp(), want)
		}
	})

	t.Run("falls back to now on an unparsable timestamp", func(t *testing.T) {
		// eos always sends RFC3339Nano, but a record must still ship with a
		// usable timestamp rather than the zero time if that ever changes.
		for _, ts := range []string{"", "not-a-timestamp", "2026-08-17 05:30:00"} {
			lr := buildRecord(record{TS: ts, Stream: "stdout", Msg: "x"}, now)
			if !lr.Timestamp().Equal(fallback) {
				t.Errorf("ts %q: timestamp = %v, want the fallback %v", ts, lr.Timestamp(), fallback)
			}
			if got := lr.Severity(); got != otellog.SeverityInfo {
				t.Errorf("ts %q: severity = %v, want %v", ts, got, otellog.SeverityInfo)
			}
		}
	})

	t.Run("keeps an empty message and stream", func(t *testing.T) {
		lr := buildRecord(record{TS: "2026-08-17T05:30:00Z"}, now)
		if got := lr.Body().AsString(); got != "" {
			t.Errorf("body = %q, want empty", got)
		}
		if _, ok := attrs(t, &lr)["log.iostream"]; !ok {
			t.Error("log.iostream missing; the attribute should be present even when the stream is empty")
		}
	})
}

// clearSinkEnv gives each run test a known environment. eos sets these
// variables when it launches a sink (PROTOCOL.md); a stray value inherited
// from the developer's shell would make a test pass or fail for the wrong
// reason.
func clearSinkEnv(t *testing.T) {
	t.Helper()
	for _, k := range []string{"EOS_SINK_ADDRESS", "EOS_SINK_SERVICE", "EOS_SINK_OPTIONS"} {
		t.Setenv(k, "")
		if err := os.Unsetenv(k); err != nil {
			t.Fatalf("unsetting %s: %v", k, err)
		}
	}
}

func TestRunRejectsBadConfiguration(t *testing.T) {
	cases := []struct {
		name    string
		env     map[string]string
		wantErr string
	}{
		{
			name:    "no address",
			env:     map[string]string{"EOS_SINK_SERVICE": "demo"},
			wantErr: "missing required EOS_SINK_ADDRESS",
		},
		{
			// eos resolves the service name; without one the exporter would
			// publish logs no backend can attribute to anything.
			name:    "no service name from either source",
			env:     map[string]string{"EOS_SINK_ADDRESS": "127.0.0.1:4317"},
			wantErr: "missing service name",
		},
		{
			name: "unparsable options",
			env: map[string]string{
				"EOS_SINK_ADDRESS": "127.0.0.1:4317",
				"EOS_SINK_SERVICE": "demo",
				"EOS_SINK_OPTIONS": "{not json",
			},
			wantErr: "parsing EOS_SINK_OPTIONS",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			clearSinkEnv(t)
			for k, v := range c.env {
				t.Setenv(k, v)
			}

			err := run(t.Context(), strings.NewReader(""))
			if err == nil {
				t.Fatalf("run = nil error, want %q", c.wantErr)
			}
			if !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("run error = %q, want it to contain %q", err, c.wantErr)
			}
		})
	}
}

func TestRunTakesServiceNameFromOptions(t *testing.T) {
	// options.service_name overrides EOS_SINK_SERVICE, so a bare address with
	// only the option set must be accepted rather than rejected as nameless.
	clearSinkEnv(t)
	t.Setenv("EOS_SINK_ADDRESS", "127.0.0.1:4317")
	t.Setenv("EOS_SINK_OPTIONS", `{"service_name":"from-options","insecure":true,"headers":{"x-tenant":"acme"}}`)

	if err := run(t.Context(), strings.NewReader("")); err != nil {
		t.Fatalf("run = %v, want nil", err)
	}
}

func TestRunConsumesRecordsAndExitsCleanly(t *testing.T) {
	// End of stdin is a normal shutdown, not an error: eos closes stdin and
	// kills the plugin 3s later (PROTOCOL.md), so run must drain, flush inside
	// that window and return nil -- with no collector listening, which is also
	// what a misconfigured host looks like.
	clearSinkEnv(t)
	t.Setenv("EOS_SINK_ADDRESS", "http://127.0.0.1:4317")
	t.Setenv("EOS_SINK_SERVICE", "demo")

	input := strings.Join([]string{
		`{"ts":"2026-08-17T05:30:00Z","service":"demo","stream":"stderr","msg":"disk full"}`,
		`{"ts":"nonsense","service":"demo","stream":"stdout","msg":"fallback timestamp"}`,
		`{not json at all`,
		"",
	}, "\n")

	if err := run(t.Context(), strings.NewReader(input)); err != nil {
		t.Fatalf("run = %v, want nil", err)
	}
}
