package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"syscall"
	"time"
)

type record struct {
	TS     string `json:"ts"`
	Stream string `json:"stream"`
	Msg    string `json:"msg"`
}

type lokiStream struct {
	Stream map[string]string `json:"stream"`
	Values [][2]string       `json:"values"`
}

type lokiPush struct {
	Streams []lokiStream `json:"streams"`
}

func main() {
	runtime.GOMAXPROCS(1)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	if err := run(ctx, os.Stdin); err != nil {
		stop()
		fmt.Fprintf(os.Stderr, "eos-sink-loki: %v\n", err)
		os.Exit(1)
	}
	stop()
}

func run(ctx context.Context, in io.Reader) error {
	address := strings.TrimRight(os.Getenv("EOS_SINK_ADDRESS"), "/")
	if address == "" {
		return fmt.Errorf("missing required EOS_SINK_ADDRESS")
	}
	service := os.Getenv("EOS_SINK_SERVICE")

	url := address + "/loki/api/v1/push"
	client := &http.Client{Timeout: 5 * time.Second}

	fmt.Println("READY")
	fmt.Printf("eos-sink-loki: ready — endpoint=%s service=%s\n", url, service)

	sc := bufio.NewScanner(in)
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			continue
		}

		var rec record
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			fmt.Fprintf(os.Stderr, "eos-sink-loki: parse record: %v\n", err)
			continue
		}

		level := "info"
		if rec.Stream == "stderr" {
			level = "error"
		}

		ts, err := time.Parse(time.RFC3339Nano, rec.TS)
		if err != nil {
			ts = time.Now()
		}
		nsStr := fmt.Sprintf("%d", ts.UnixNano())

		push := lokiPush{Streams: []lokiStream{{
			Stream: map[string]string{"service": service, "level": level},
			Values: [][2]string{{nsStr, rec.Msg}},
		}}}

		body, _ := json.Marshal(push)
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body)) // #nosec G704 -- URL from trusted EOS_SINK_ADDRESS env var
		if err != nil {
			fmt.Fprintf(os.Stderr, "eos-sink-loki: build request: %v\n", err)
			continue
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := client.Do(req) // #nosec G704
		if err != nil {
			fmt.Fprintf(os.Stderr, "eos-sink-loki: post: %v\n", err)
			continue
		}
		if resp != nil {
			if closeErr := resp.Body.Close(); closeErr != nil {
				fmt.Fprintf(os.Stderr, "eos-sink-loki: close body: %v\n", closeErr)
			}
		}
	}
	if err := sc.Err(); err != nil {
		return fmt.Errorf("reading stdin: %w", err)
	}
	return nil
}
