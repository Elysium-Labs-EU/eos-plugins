package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"syscall"
	"time"

	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	otellog "go.opentelemetry.io/otel/log"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.27.0"
)

type record struct {
	TS      string `json:"ts"`
	Service string `json:"service"`
	Stream  string `json:"stream"`
	Msg     string `json:"msg"`
}

type sinkOptions struct {
	Headers     map[string]string `json:"headers"`
	ServiceName string            `json:"service_name"`
	Insecure    bool              `json:"insecure"`
}

func main() {
	runtime.GOMAXPROCS(1)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	if err := run(ctx, os.Stdin); err != nil {
		stop()
		fmt.Fprintf(os.Stderr, "eos-sink-otlp: %v\n", err)
		os.Exit(1)
	}
	stop()
}

func run(ctx context.Context, in io.Reader) error {
	address := os.Getenv("EOS_SINK_ADDRESS")
	if address == "" {
		return fmt.Errorf("missing required EOS_SINK_ADDRESS")
	}
	service := os.Getenv("EOS_SINK_SERVICE")

	var opts sinkOptions
	if raw := os.Getenv("EOS_SINK_OPTIONS"); raw != "" {
		if err := json.Unmarshal([]byte(raw), &opts); err != nil {
			return fmt.Errorf("parsing EOS_SINK_OPTIONS: %w", err)
		}
	}

	serviceName := service
	if opts.ServiceName != "" {
		serviceName = opts.ServiceName
	}
	if serviceName == "" {
		return fmt.Errorf("missing service name: set EOS_SINK_SERVICE or options.service_name")
	}

	endpoint, insecure := parseEndpoint(address, opts.Insecure)

	exporterOpts := []otlploggrpc.Option{otlploggrpc.WithEndpoint(endpoint)}
	if insecure {
		exporterOpts = append(exporterOpts, otlploggrpc.WithInsecure())
	}
	if len(opts.Headers) > 0 {
		exporterOpts = append(exporterOpts, otlploggrpc.WithHeaders(opts.Headers))
	}

	exporter, err := otlploggrpc.New(ctx, exporterOpts...)
	if err != nil {
		return fmt.Errorf("creating otlp exporter: %w", err)
	}

	res, err := resource.New(ctx, resource.WithAttributes(semconv.ServiceName(serviceName)))
	if err != nil {
		return fmt.Errorf("building resource: %w", err)
	}

	processor := sdklog.NewBatchProcessor(exporter)
	provider := sdklog.NewLoggerProvider(
		sdklog.WithResource(res),
		sdklog.WithProcessor(processor),
	)
	defer func() { //nolint:contextcheck // deliberately not deriving from ctx: it's already canceled by the signal that triggered this shutdown, and we need a live context to flush within eos's 3s kill window
		// eos kills the plugin 3s after closing stdin (PROTOCOL.md), so flush the
		// final batch inside that window rather than risk being killed mid-flush.
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2500*time.Millisecond)
		defer cancel()
		_ = provider.Shutdown(shutdownCtx)
	}()

	logger := provider.Logger("eos-sink-otlp")

	fmt.Println("READY")
	fmt.Fprintf(os.Stderr, "eos-sink-otlp: ready; endpoint=%s insecure=%v service=%s\n", endpoint, insecure, serviceName)

	return readNDJSON(in, func(line string) {
		var rec record
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			fmt.Fprintf(os.Stderr, "eos-sink-otlp: parse record: %v\n", err)
			return
		}

		ts, err := time.Parse(time.RFC3339Nano, rec.TS)
		if err != nil {
			ts = time.Now()
		}

		severity := severityFor(rec.Stream)

		var lr otellog.Record
		lr.SetTimestamp(ts)
		lr.SetObservedTimestamp(ts)
		lr.SetBody(otellog.StringValue(rec.Msg))
		lr.SetSeverity(severity)
		lr.AddAttributes(otellog.KeyValue{Key: "log.iostream", Value: otellog.StringValue(rec.Stream)})

		logger.Emit(ctx, lr)
	})
}

// readNDJSON calls handle once per newline-delimited line read from r, with
// the trailing newline (and any \r) stripped. Unlike bufio.Scanner, which
// aborts the whole read on any single line over its 64KB token limit,
// bufio.Reader.ReadString has no line-length cap: a service that happens to
// emit one oversized log line must not stop ingestion for every line after
// it. Only a genuine read error (not io.EOF) stops the loop.
func readNDJSON(r io.Reader, handle func(line string)) error {
	reader := bufio.NewReader(r)
	for {
		line, err := reader.ReadString('\n')
		line = strings.TrimRight(line, "\r\n")
		if line != "" {
			handle(line)
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("reading stdin: %w", err)
		}
	}
}

// severityFor maps an eos stream name to an OTLP log severity. The stderr
// stream is Error; everything else (stdout included) is Info.
func severityFor(stream string) otellog.Severity {
	if stream == "stderr" {
		return otellog.SeverityError
	}
	return otellog.SeverityInfo
}

// parseEndpoint strips the scheme from address and reports whether the
// gRPC connection should be insecure. https:// enables TLS; http:// or no
// scheme is insecure. forceInsecure (options.insecure) always wins.
func parseEndpoint(address string, forceInsecure bool) (endpoint string, insecure bool) {
	switch {
	case strings.HasPrefix(address, "https://"):
		return strings.TrimPrefix(address, "https://"), forceInsecure
	case strings.HasPrefix(address, "http://"):
		return strings.TrimPrefix(address, "http://"), true
	default:
		return address, true
	}
}
