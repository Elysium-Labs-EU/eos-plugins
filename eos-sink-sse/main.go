package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"syscall"
)

type broker struct {
	clients map[chan string]struct{}
	mu      sync.Mutex
}

func newBroker() *broker {
	return &broker{clients: make(map[chan string]struct{})}
}

func (b *broker) subscribe() chan string {
	ch := make(chan string, 64)
	b.mu.Lock()
	b.clients[ch] = struct{}{}
	b.mu.Unlock()
	return ch
}

func (b *broker) unsubscribe(ch chan string) {
	b.mu.Lock()
	delete(b.clients, ch)
	b.mu.Unlock()
}

func (b *broker) publish(msg string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.clients {
		select {
		case ch <- msg:
		default:
		}
	}
}

func main() {
	runtime.GOMAXPROCS(1)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	if err := run(ctx, os.Stdin); err != nil {
		stop()
		fmt.Fprintf(os.Stderr, "eos-sink-sse: %v\n", err)
		os.Exit(1)
	}
	stop()
}

func run(ctx context.Context, in io.Reader) error {
	address := os.Getenv("EOS_SINK_ADDRESS")
	if address == "" {
		address = ":9000"
	}

	b := newBroker()

	mux := http.NewServeMux()
	mux.HandleFunc("/stream", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		w.Header().Set("Access-Control-Allow-Origin", "*")

		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming unsupported", http.StatusInternalServerError)
			return
		}
		flusher.Flush()

		ch := b.subscribe()
		defer b.unsubscribe(ch)

		for {
			select {
			case msg := <-ch:
				if _, err := fmt.Fprintf(w, "data: %s\n\n", msg); err != nil {
					return
				}
				flusher.Flush()
			case <-r.Context().Done():
				return
			case <-ctx.Done():
				return
			}
		}
	})

	ln, err := net.Listen("tcp", address)
	if err != nil {
		return fmt.Errorf("listen %s: %w", address, err)
	}

	srv := &http.Server{Handler: mux}
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			fmt.Fprintf(os.Stderr, "eos-sink-sse: server: %v\n", err)
		}
	}()

	fmt.Println("READY")
	fmt.Printf("eos-sink-sse: ready — serving SSE on %s/stream\n", address)

	sc := bufio.NewScanner(in)
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			continue
		}
		b.publish(line)
	}

	if err := sc.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "eos-sink-sse: reading stdin: %v\n", err)
	}
	_ = srv.Shutdown(ctx)
	return nil
}
