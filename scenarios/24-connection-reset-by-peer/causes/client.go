// rstclient: one (a single request), sweep (keepalive race), load (rollout load).
package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"net/http/httptrace"
	"os"
	"regexp"
	"sort"
	"sync"
	"time"
)

type pacer struct{ left int }

func (p *pacer) Read(b []byte) (int, error) {
	if p.left <= 0 {
		return 0, io.EOF
	}
	n := 256 * 1024
	if n > len(b) {
		n = len(b)
	}
	if n > p.left {
		n = p.left
	}
	p.left -= n
	time.Sleep(time.Duration(n) * time.Second / (1 << 20))
	return n, nil
}

var addr = regexp.MustCompile(`\d+\.\d+\.\d+\.\d+:\d+`)

func norm(err error) string { return addr.ReplaceAllString(err.Error(), "<addr>") }

func dump(m map[string]int) {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Printf("%6d  %s\n", m[k], k)
	}
}

func one(args []string) {
	fs := flag.NewFlagSet("one", flag.ExitOnError)
	method := fs.String("X", "GET", "")
	mb := fs.Int("mb", 0, "upload MB, paced at 1 MiB/s")
	fs.Parse(args)
	var body io.Reader
	if *mb > 0 {
		body = &pacer{*mb << 20}
	}
	req, _ := http.NewRequest(*method, fs.Arg(0), body)
	resp, err := (&http.Client{Timeout: 90 * time.Second}).Do(req)
	if err != nil {
		fmt.Println("go net/http error:", err)
		return
	}
	defer resp.Body.Close()
	n, err := io.Copy(io.Discard, resp.Body)
	fmt.Println("go net/http status:", resp.StatusCode, "body bytes:", n, "body read error:", err)
}

func sweep(args []string) {
	fs := flag.NewFlagSet("sweep", flag.ExitOnError)
	method := fs.String("X", "POST", "")
	idle := fs.Duration("idle", 2*time.Second, "")
	window := fs.Duration("window", 5*time.Millisecond, "")
	conns := fs.Int("c", 50, "")
	rounds := fs.Int("n", 60, "")
	fs.Parse(args)
	url := fs.Arg(0)
	var mu sync.Mutex
	res := map[string]int{}
	var wg sync.WaitGroup
	do := func(c *http.Client, trace *httptrace.ClientTrace) error {
		req, _ := http.NewRequestWithContext(httptrace.WithClientTrace(context.Background(), trace), *method, url, bytes.NewReader([]byte("x")))
		resp, err := c.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		_, err = io.Copy(io.Discard, resp.Body)
		return err
	}
	for i := 0; i < *conns; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			time.Sleep(time.Duration(rand.Intn(1000)) * time.Millisecond)
			for r := 0; r < *rounds; r++ {
				tr := &http.Transport{MaxIdleConnsPerHost: 1}
				c := &http.Client{Transport: tr, Timeout: 5 * time.Second}
				var local string
				var reused bool
				trace := &httptrace.ClientTrace{GotConn: func(g httptrace.GotConnInfo) { local = g.Conn.LocalAddr().String(); reused = g.Reused }}
				if err := do(c, trace); err != nil {
					continue
				}
				off := time.Duration(rand.Int63n(int64(2**window))) - *window
				time.Sleep(*idle + off)
				err := do(c, trace)
				mu.Lock()
				switch {
				case err != nil:
					res["reused="+fmt.Sprint(reused)+" error: "+norm(err)]++
					fmt.Printf("FAIL local=%s offset=%s reused=%v err=%v\n", local, off, reused, err)
				default:
					res["reused="+fmt.Sprint(reused)+" ok"]++
				}
				mu.Unlock()
				tr.CloseIdleConnections()
			}
		}()
	}
	wg.Wait()
	fmt.Println("summary:")
	dump(res)
}

func load(args []string) {
	fs := flag.NewFlagSet("load", flag.ExitOnError)
	d := fs.Duration("d", 60*time.Second, "")
	c := fs.Int("c", 8, "")
	keep := fs.Bool("keepalive", false, "")
	fs.Parse(args)
	url := fs.Arg(0)
	var mu sync.Mutex
	res := map[string]int{}
	end := time.Now().Add(*d)
	var wg sync.WaitGroup
	for i := 0; i < *c; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			cl := &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{DisableKeepAlives: !*keep, MaxIdleConnsPerHost: 1}}
			for time.Now().Before(end) {
				req, _ := http.NewRequest("POST", url, bytes.NewReader([]byte("x")))
				resp, err := cl.Do(req)
				k := ""
				if err != nil {
					k = "error: " + norm(err)
				} else {
					_, e := io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
					k = fmt.Sprint("status ", resp.StatusCode)
					if e != nil {
						k = "body error: " + norm(e)
					}
				}
				mu.Lock()
				res[k]++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	dump(res)
}

func main() {
	if len(os.Args) < 2 {
		os.Exit(2)
	}
	switch os.Args[1] {
	case "one":
		one(os.Args[2:])
	case "sweep":
		sweep(os.Args[2:])
	case "load":
		load(os.Args[2:])
	}
}
