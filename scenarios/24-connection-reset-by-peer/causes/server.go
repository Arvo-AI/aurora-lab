// Test server for the RST reproductions. DRAIN=1 turns on graceful shutdown;
// without it the Go runtime's default SIGTERM behaviour applies: exit at once.
package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func intq(r *http.Request, k string, d int) int {
	if v, err := strconv.Atoi(r.URL.Query().Get(k)); err == nil {
		return v
	}
	return d
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintln(w, "ok") })
	mux.HandleFunc("/ok", func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		time.Sleep(time.Duration(intq(r, "ms", 200)) * time.Millisecond)
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("/crash", func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(time.Duration(intq(r, "ms", 500)) * time.Millisecond)
		os.Exit(1)
	})
	mux.HandleFunc("/stream", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", strconv.Itoa(1<<30))
		buf := make([]byte, 16384)
		for {
			if _, err := w.Write(buf); err != nil {
				return
			}
			w.(http.Flusher).Flush()
			time.Sleep(100 * time.Millisecond)
		}
	})
	// fast=1 reads as quickly as the client sends; otherwise 64 KiB per 100 ms,
	// so a faster client leaves unread bytes in the socket receive buffer.
	mux.HandleFunc("/upload", func(w http.ResponseWriter, r *http.Request) {
		fast := r.URL.Query().Get("fast") == "1"
		buf := make([]byte, 65536)
		total := 0
		for {
			n, err := r.Body.Read(buf)
			total += n
			if err != nil {
				break
			}
			if !fast {
				time.Sleep(100 * time.Millisecond)
			}
		}
		fmt.Fprintln(w, total)
	})
	mux.HandleFunc("/oom", func(w http.ResponseWriter, r *http.Request) {
		var keep [][]byte
		for {
			b := make([]byte, 8<<20)
			for i := 0; i < len(b); i += 4096 {
				b[i] = 1
			}
			keep = append(keep, b)
			time.Sleep(20 * time.Millisecond)
		}
	})
	done := make(chan struct{})
	srv := &http.Server{Addr: ":8080", Handler: mux}
	if ms, err := strconv.Atoi(os.Getenv("IDLE_MS")); err == nil {
		srv.IdleTimeout = time.Duration(ms) * time.Millisecond
	}
	if os.Getenv("DRAIN") == "1" {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGTERM)
		go func() {
			<-sig
			log.Print("SIGTERM: draining")
			ctx, c := context.WithTimeout(context.Background(), 25*time.Second)
			defer c()
			srv.Shutdown(ctx)
			close(done)
		}()
	}
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatal(err)
	}
	<-done
}
