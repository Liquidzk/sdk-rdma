package main

import (
	"context"
	"errors"
	"flag"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

var hopHeaders = []string{
	"Connection",
	"Proxy-Connection",
	"Keep-Alive",
	"Proxy-Authenticate",
	"Proxy-Authorization",
	"Te",
	"Trailer",
	"Transfer-Encoding",
	"Upgrade",
}

type relay struct {
	upstream *url.URL
	client   *http.Client
}

func main() {
	var listenAddr string
	var minioEndpoint string
	flag.StringVar(&listenAddr, "listen", getenv("LISTEN_ADDR", ":18080"), "listen address")
	flag.StringVar(&minioEndpoint, "minio-endpoint", getenv("MINIO_ENDPOINT", "http://127.0.0.1:9000"), "MinIO upstream endpoint")
	flag.Parse()

	upstream, err := url.Parse(minioEndpoint)
	if err != nil {
		log.Fatalf("invalid -minio-endpoint: %v", err)
	}
	if upstream.Scheme != "http" && upstream.Scheme != "https" {
		log.Fatalf("unsupported upstream scheme %q", upstream.Scheme)
	}

	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		MaxIdleConns:          512,
		MaxIdleConnsPerHost:   256,
		IdleConnTimeout:       90 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		ForceAttemptHTTP2:     false,
	}

	h := &relay{
		upstream: upstream,
		client: &http.Client{
			Transport: transport,
		},
	}

	srv := &http.Server{
		Addr:              listenAddr,
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		sigC := make(chan os.Signal, 1)
		signal.Notify(sigC, syscall.SIGTERM, syscall.SIGINT)
		<-sigC

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Printf("server shutdown error: %v", err)
		}
	}()

	log.Printf("rdma-http relay listening on %s -> %s", listenAddr, upstream.String())
	err = srv.ListenAndServe()
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("listen error: %v", err)
	}
	<-shutdownDone
}

func (p *relay) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	if r.Method == http.MethodGet && r.URL.Path == "/_rdma_healthz" {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
		return
	}

	outReq := r.Clone(r.Context())
	outReq.URL.Scheme = p.upstream.Scheme
	outReq.URL.Host = p.upstream.Host
	outReq.URL.Path = joinPath(p.upstream.Path, r.URL.Path)
	outReq.URL.RawPath = joinPath(p.upstream.EscapedPath(), r.URL.EscapedPath())
	outReq.RequestURI = ""

	// Keep Host untouched so SigV4 host header signed by client remains valid.
	outReq.Host = r.Host

	removeHopHeaders(outReq.Header)

	resp, err := p.client.Do(outReq)
	if err != nil {
		status := http.StatusBadGateway
		http.Error(w, "upstream request failed: "+err.Error(), status)
		log.Printf("proxy_error method=%s path=%s status=%d err=%v dur=%s", r.Method, r.URL.RequestURI(), status, err, time.Since(start))
		return
	}
	defer resp.Body.Close()

	removeHopHeaders(resp.Header)
	copyHeader(w.Header(), resp.Header)
	w.WriteHeader(resp.StatusCode)
	_, copyErr := io.Copy(w, resp.Body)
	if copyErr != nil && !errors.Is(copyErr, context.Canceled) {
		log.Printf("copy_response_error method=%s path=%s err=%v", r.Method, r.URL.RequestURI(), copyErr)
	}

	log.Printf("proxied method=%s path=%s status=%d bytes_in=%d bytes_out=%d dur=%s", r.Method, r.URL.RequestURI(), resp.StatusCode, r.ContentLength, resp.ContentLength, time.Since(start))
}

func copyHeader(dst, src http.Header) {
	for k, vv := range src {
		for _, v := range vv {
			dst.Add(k, v)
		}
	}
}

func removeHopHeaders(h http.Header) {
	if h == nil {
		return
	}
	if c := h.Get("Connection"); c != "" {
		for _, token := range strings.Split(c, ",") {
			h.Del(strings.TrimSpace(token))
		}
	}
	for _, k := range hopHeaders {
		h.Del(k)
	}
}

func joinPath(a, b string) string {
	switch {
	case a == "":
		return b
	case b == "":
		return a
	}
	aSlash := strings.HasSuffix(a, "/")
	bSlash := strings.HasPrefix(b, "/")
	switch {
	case aSlash && bSlash:
		return a + b[1:]
	case !aSlash && !bSlash:
		return a + "/" + b
	default:
		return a + b
	}
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
