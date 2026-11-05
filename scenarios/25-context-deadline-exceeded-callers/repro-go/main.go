// Prints what each Go timeout mechanism actually says, and against which server.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health/grpc_health_v1"
)

func report(name string, err error) {
	var ne net.Error
	isNet := errors.As(err, &ne) && ne.Timeout()
	fmt.Printf("%-34s %v\n%-34s errors.Is(DeadlineExceeded)=%v net.Error.Timeout=%v\n", name, err, "", errors.Is(err, context.DeadlineExceeded), isNet)
}

func main() {
	fmt.Printf("%-34s %q\n", "context.DeadlineExceeded.Error()", context.DeadlineExceeded.Error())

	hang := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(3 * time.Second)
	}))
	defer hang.Close()
	drip := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		time.Sleep(3 * time.Second)
	}))
	defer drip.Close()

	// 1. http.Client.Timeout, server sends no headers.
	c := &http.Client{Timeout: 200 * time.Millisecond}
	_, err := c.Get(hang.URL)
	report("Client.Timeout, no headers", err)

	// 2. http.Client.Timeout, headers arrive, body stalls.
	r, err := c.Get(drip.URL)
	if err == nil {
		_, err = io.ReadAll(r.Body)
		r.Body.Close()
	}
	report("Client.Timeout, body stalls", err)

	// 3. Caller's context, no Client.Timeout.
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", hang.URL, nil)
	_, err = http.DefaultClient.Do(req)
	report("context.WithTimeout, no headers", err)

	// 4. net.Dialer.Timeout to an address that drops packets.
	_, err = (&net.Dialer{Timeout: 200 * time.Millisecond}).Dial("tcp", "192.0.2.10:80")
	report("net.Dialer.Timeout, dropped SYN", err)

	// 5. http.Client.Timeout to an address that drops packets.
	_, err = c.Get("http://192.0.2.10/")
	report("Client.Timeout, dropped SYN", err)

	// 6. gRPC call whose context expires; the handler outlives it.
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	s := grpc.NewServer()
	grpc_health_v1.RegisterHealthServer(s, slowHealth{})
	go s.Serve(l)
	defer s.Stop()
	cc, e := grpc.NewClient(l.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if e != nil {
		fmt.Println(e)
		os.Exit(1)
	}
	defer cc.Close()
	gctx, gcancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer gcancel()
	_, err = grpc_health_v1.NewHealthClient(cc).Check(gctx, &grpc_health_v1.HealthCheckRequest{})
	report("gRPC call, context expires", err)
}

type slowHealth struct {
	grpc_health_v1.UnimplementedHealthServer
}

func (slowHealth) Check(ctx context.Context, _ *grpc_health_v1.HealthCheckRequest) (*grpc_health_v1.HealthCheckResponse, error) {
	time.Sleep(time.Second)
	return &grpc_health_v1.HealthCheckResponse{}, nil
}
