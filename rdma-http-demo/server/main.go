package main

import (
	"context"
	"errors"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	awsrdmahttp "github.com/aws/aws-sdk-go-v2/aws/transport/http/rdma"
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
	upstream    *url.URL
	client      *http.Client
	inflightSem chan struct{}
	accessLog   bool
	stats       *relayStats
}

type relayStats struct {
	startedAt time.Time

	inflight     atomic.Int64
	inflightMax  atomic.Int64
	requests     atomic.Int64
	status2xx    atomic.Int64
	status4xx    atomic.Int64
	status5xx    atomic.Int64
	overloadDrop atomic.Int64
	upstreamErr  atomic.Int64
	copyErr      atomic.Int64
	bytesIn      atomic.Int64
	bytesOut     atomic.Int64
	latencyTotal atomic.Int64
	latencyMax   atomic.Int64
}

type relayStatsSnapshot struct {
	UptimeSeconds     float64 `json:"uptime_seconds"`
	Requests          int64   `json:"requests_total"`
	Inflight          int64   `json:"inflight"`
	InflightMax       int64   `json:"inflight_max"`
	Status2xx         int64   `json:"status_2xx"`
	Status4xx         int64   `json:"status_4xx"`
	Status5xx         int64   `json:"status_5xx"`
	OverloadDrops     int64   `json:"overload_drops"`
	UpstreamErrors    int64   `json:"upstream_errors"`
	CopyErrors        int64   `json:"copy_errors"`
	BytesIn           int64   `json:"bytes_in"`
	BytesOut          int64   `json:"bytes_out"`
	AvgLatencyMillis  float64 `json:"avg_latency_ms"`
	P95LikeLatencyMs  float64 `json:"p95_like_latency_ms"`
	MaxLatencyMillis  float64 `json:"max_latency_ms"`
	AverageRequestQPS float64 `json:"average_qps"`
}

func newRelayStats() *relayStats {
	return &relayStats{
		startedAt: time.Now(),
	}
}

func (s *relayStats) begin() {
	s.requests.Add(1)
	inflight := s.inflight.Add(1)
	updateAtomicMaxInt64(&s.inflightMax, inflight)
}

func (s *relayStats) end(statusCode int, bytesIn, bytesOut int64, dur time.Duration) {
	s.inflight.Add(-1)

	if statusCode >= 500 {
		s.status5xx.Add(1)
	} else if statusCode >= 400 {
		s.status4xx.Add(1)
	} else if statusCode >= 200 {
		s.status2xx.Add(1)
	}

	if bytesIn > 0 {
		s.bytesIn.Add(bytesIn)
	}
	if bytesOut > 0 {
		s.bytesOut.Add(bytesOut)
	}

	latNs := dur.Nanoseconds()
	s.latencyTotal.Add(latNs)
	updateAtomicMaxInt64(&s.latencyMax, latNs)
}

func (s *relayStats) snapshot() relayStatsSnapshot {
	now := time.Now()
	up := now.Sub(s.startedAt)
	upSec := up.Seconds()
	if upSec <= 0 {
		upSec = 1e-9
	}

	req := s.requests.Load()
	totalLatNs := s.latencyTotal.Load()
	avgLatMs := 0.0
	p95LikeMs := 0.0
	if req > 0 {
		avgLatMs = float64(totalLatNs) / float64(req) / float64(time.Millisecond)
		// Exponential-ish high-percentile proxy from avg/max for low-overhead logging.
		p95LikeMs = (avgLatMs * 0.4) + (float64(s.latencyMax.Load())/float64(time.Millisecond))*0.6
	}

	return relayStatsSnapshot{
		UptimeSeconds:     upSec,
		Requests:          req,
		Inflight:          s.inflight.Load(),
		InflightMax:       s.inflightMax.Load(),
		Status2xx:         s.status2xx.Load(),
		Status4xx:         s.status4xx.Load(),
		Status5xx:         s.status5xx.Load(),
		OverloadDrops:     s.overloadDrop.Load(),
		UpstreamErrors:    s.upstreamErr.Load(),
		CopyErrors:        s.copyErr.Load(),
		BytesIn:           s.bytesIn.Load(),
		BytesOut:          s.bytesOut.Load(),
		AvgLatencyMillis:  avgLatMs,
		P95LikeLatencyMs:  p95LikeMs,
		MaxLatencyMillis:  float64(s.latencyMax.Load()) / float64(time.Millisecond),
		AverageRequestQPS: float64(req) / upSec,
	}
}

func updateAtomicMaxInt64(target *atomic.Int64, v int64) {
	for {
		cur := target.Load()
		if v <= cur {
			return
		}
		if target.CompareAndSwap(cur, v) {
			return
		}
	}
}

func logStatsPeriodically(stats *relayStats, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()

	for range t.C {
		snap := stats.snapshot()
		log.Printf(
			"relay_stats req=%d inflight=%d inflight_max=%d qps=%.2f status2xx=%d status4xx=%d status5xx=%d overload=%d upstream_err=%d copy_err=%d bytes_in=%d bytes_out=%d avg_ms=%.3f p95_like_ms=%.3f max_ms=%.3f",
			snap.Requests,
			snap.Inflight,
			snap.InflightMax,
			snap.AverageRequestQPS,
			snap.Status2xx,
			snap.Status4xx,
			snap.Status5xx,
			snap.OverloadDrops,
			snap.UpstreamErrors,
			snap.CopyErrors,
			snap.BytesIn,
			snap.BytesOut,
			snap.AvgLatencyMillis,
			snap.P95LikeLatencyMs,
			snap.MaxLatencyMillis,
		)
	}
}

func main() {
	var listenAddr string
	var minioEndpoint string
	var enableRDMA bool
	var disableClientKeepAlive bool
	var rdmaNetwork string
	var rdmaBacklog int
	var rdmaFramePayload int
	var rdmaSendQueueDepth int
	var rdmaRecvQueueDepth int
	var rdmaInlineThreshold int
	var accessLog bool
	var statsInterval time.Duration
	var maxInflight int
	var upstreamMaxIdleConns int
	var upstreamMaxIdleConnsPerHost int
	var upstreamMaxConnsPerHost int
	var upstreamIdleConnTimeout time.Duration
	var upstreamResponseHeaderTimeout time.Duration
	var upstreamDisableCompression bool
	var serverReadHeaderTimeout time.Duration
	var serverReadTimeout time.Duration
	var serverWriteTimeout time.Duration
	var serverIdleTimeout time.Duration
	var serverMaxHeaderBytes int
	flag.StringVar(&listenAddr, "listen", getenv("LISTEN_ADDR", ":18080"), "listen address")
	flag.StringVar(&minioEndpoint, "minio-endpoint", getenv("MINIO_ENDPOINT", "http://127.0.0.1:9000"), "MinIO upstream endpoint")
	flag.BoolVar(&enableRDMA, "rdma", true, "enable RDMA verbs listener for incoming connections")
	flag.BoolVar(&disableClientKeepAlive, "disable-client-keepalive", false, "force close relay-side client connections after each response")
	flag.StringVar(&rdmaNetwork, "rdma-network", getenv("RDMA_NETWORK", "rdma"), "RDMA listener network: rdma|rdma4|rdma6")
	flag.IntVar(&rdmaBacklog, "rdma-backlog", 0, "RDMA listen backlog (0 uses SDK defaults)")
	flag.IntVar(&rdmaFramePayload, "rdma-frame-payload", 0, "RDMA frame payload bytes (0 uses SDK defaults)")
	flag.IntVar(&rdmaSendQueueDepth, "rdma-sendq", 0, "RDMA send queue depth (0 uses SDK defaults)")
	flag.IntVar(&rdmaRecvQueueDepth, "rdma-recvq", 0, "RDMA recv queue depth (0 uses SDK defaults)")
	flag.IntVar(&rdmaInlineThreshold, "rdma-inline", 0, "RDMA inline threshold bytes (0 uses SDK defaults)")
	flag.BoolVar(&accessLog, "access-log", getenvBool("RELAY_ACCESS_LOG", true), "log one line per proxied request")
	flag.DurationVar(&statsInterval, "stats-interval", getenvDuration("RELAY_STATS_INTERVAL", 30*time.Second), "periodic relay stats log interval (0 disables)")
	flag.IntVar(&maxInflight, "max-inflight", getenvInt("RELAY_MAX_INFLIGHT", 0), "max in-flight requests (0 disables overload shedding)")
	flag.IntVar(&upstreamMaxIdleConns, "upstream-max-idle-conns", getenvInt("RELAY_UPSTREAM_MAX_IDLE_CONNS", 1024), "upstream transport max idle conns")
	flag.IntVar(&upstreamMaxIdleConnsPerHost, "upstream-max-idle-conns-per-host", getenvInt("RELAY_UPSTREAM_MAX_IDLE_CONNS_PER_HOST", 512), "upstream transport max idle conns per host")
	flag.IntVar(&upstreamMaxConnsPerHost, "upstream-max-conns-per-host", getenvInt("RELAY_UPSTREAM_MAX_CONNS_PER_HOST", 0), "upstream transport max total conns per host (0 = unlimited)")
	flag.DurationVar(&upstreamIdleConnTimeout, "upstream-idle-conn-timeout", getenvDuration("RELAY_UPSTREAM_IDLE_CONN_TIMEOUT", 120*time.Second), "upstream idle connection timeout")
	flag.DurationVar(&upstreamResponseHeaderTimeout, "upstream-response-header-timeout", getenvDuration("RELAY_UPSTREAM_RESPONSE_HEADER_TIMEOUT", 15*time.Second), "upstream response header timeout")
	flag.BoolVar(&upstreamDisableCompression, "upstream-disable-compression", getenvBool("RELAY_UPSTREAM_DISABLE_COMPRESSION", true), "disable upstream gzip to save relay CPU")
	flag.DurationVar(&serverReadHeaderTimeout, "server-read-header-timeout", getenvDuration("RELAY_SERVER_READ_HEADER_TIMEOUT", 10*time.Second), "server read header timeout")
	flag.DurationVar(&serverReadTimeout, "server-read-timeout", getenvDuration("RELAY_SERVER_READ_TIMEOUT", 0), "server full request read timeout (0 disables)")
	flag.DurationVar(&serverWriteTimeout, "server-write-timeout", getenvDuration("RELAY_SERVER_WRITE_TIMEOUT", 0), "server response write timeout (0 disables)")
	flag.DurationVar(&serverIdleTimeout, "server-idle-timeout", getenvDuration("RELAY_SERVER_IDLE_TIMEOUT", 120*time.Second), "server keepalive idle timeout")
	flag.IntVar(&serverMaxHeaderBytes, "server-max-header-bytes", getenvInt("RELAY_SERVER_MAX_HEADER_BYTES", 1<<20), "server max request header bytes")
	flag.Parse()

	upstream, err := url.Parse(minioEndpoint)
	if err != nil {
		log.Fatalf("invalid -minio-endpoint: %v", err)
	}
	if upstream.Scheme != "http" && upstream.Scheme != "https" {
		log.Fatalf("unsupported upstream scheme %q", upstream.Scheme)
	}
	if maxInflight < 0 {
		log.Fatalf("invalid -max-inflight %d, must be >= 0", maxInflight)
	}
	if upstreamMaxIdleConns < 0 || upstreamMaxIdleConnsPerHost < 0 || upstreamMaxConnsPerHost < 0 {
		log.Fatalf("invalid upstream pool config: max-idle=%d max-idle-per-host=%d max-conns-per-host=%d (must be >= 0)",
			upstreamMaxIdleConns, upstreamMaxIdleConnsPerHost, upstreamMaxConnsPerHost)
	}
	if serverMaxHeaderBytes < 0 {
		log.Fatalf("invalid -server-max-header-bytes %d, must be >= 0", serverMaxHeaderBytes)
	}

	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		MaxIdleConns:          upstreamMaxIdleConns,
		MaxIdleConnsPerHost:   upstreamMaxIdleConnsPerHost,
		MaxConnsPerHost:       upstreamMaxConnsPerHost,
		IdleConnTimeout:       upstreamIdleConnTimeout,
		ResponseHeaderTimeout: upstreamResponseHeaderTimeout,
		ExpectContinueTimeout: 1 * time.Second,
		DisableCompression:    upstreamDisableCompression,
		ForceAttemptHTTP2:     false,
	}

	h := &relay{
		upstream:  upstream,
		accessLog: accessLog,
		stats:     newRelayStats(),
		client: &http.Client{
			Transport: transport,
		},
	}
	if maxInflight > 0 {
		h.inflightSem = make(chan struct{}, maxInflight)
	}
	if statsInterval > 0 {
		go logStatsPeriodically(h.stats, statsInterval)
	}

	srv := &http.Server{
		Addr:              listenAddr,
		Handler:           h,
		ReadHeaderTimeout: serverReadHeaderTimeout,
		ReadTimeout:       serverReadTimeout,
		WriteTimeout:      serverWriteTimeout,
		IdleTimeout:       serverIdleTimeout,
		MaxHeaderBytes:    serverMaxHeaderBytes,
	}
	if disableClientKeepAlive {
		srv.SetKeepAlivesEnabled(false)
	}

	ln, err := buildListener(enableRDMA, rdmaNetwork, listenAddr, awsrdmahttp.VerbsListenerOptions{
		VerbsOptions: awsrdmahttp.VerbsOptions{
			FramePayloadSize: rdmaFramePayload,
			SendQueueDepth:   rdmaSendQueueDepth,
			RecvQueueDepth:   rdmaRecvQueueDepth,
			InlineThreshold:  rdmaInlineThreshold,
		},
		Backlog: rdmaBacklog,
	})
	if err != nil {
		log.Fatalf("listener init failed: %v", err)
	}
	defer ln.Close()

	if enableRDMA {
		log.Printf(
			"rdma-http relay listening via RDMA on %s (network=%s backlog=%d frame_payload=%d sendq=%d recvq=%d inline=%d) -> %s; inflight_limit=%d upstream_pool[max_idle=%d max_idle_per_host=%d max_conns_per_host=%d idle_timeout=%s] access_log=%t stats_interval=%s",
			listenAddr, rdmaNetwork, rdmaBacklog, rdmaFramePayload, rdmaSendQueueDepth, rdmaRecvQueueDepth, rdmaInlineThreshold, upstream.String(),
			maxInflight, upstreamMaxIdleConns, upstreamMaxIdleConnsPerHost, upstreamMaxConnsPerHost, upstreamIdleConnTimeout, accessLog, statsInterval,
		)
	} else {
		log.Printf("rdma-http relay listening via TCP on %s -> %s", listenAddr, upstream.String())
	}
	err = srv.Serve(ln)
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("listen error: %v", err)
	}
}

func buildListener(enableRDMA bool, network, listenAddr string, opts awsrdmahttp.VerbsListenerOptions) (net.Listener, error) {
	if !enableRDMA {
		return net.Listen("tcp", listenAddr)
	}
	return awsrdmahttp.NewVerbsListener(network, listenAddr, opts)
}

func (p *relay) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet && r.URL.Path == "/_rdma_healthz" {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
		return
	}

	start := time.Now()
	bytesIn := r.ContentLength
	if bytesIn < 0 {
		bytesIn = 0
	}

	statusCode := 0
	bytesOut := int64(0)
	p.stats.begin()
	defer func() {
		if statusCode == 0 {
			statusCode = http.StatusInternalServerError
		}
		p.stats.end(statusCode, bytesIn, bytesOut, time.Since(start))
	}()

	if p.inflightSem != nil {
		select {
		case p.inflightSem <- struct{}{}:
			defer func() { <-p.inflightSem }()
		default:
			p.stats.overloadDrop.Add(1)
			statusCode = http.StatusServiceUnavailable
			http.Error(w, "relay overloaded", statusCode)
			if p.accessLog {
				log.Printf("overload method=%s path=%s status=%d", r.Method, r.URL.RequestURI(), statusCode)
			}
			return
		}
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
		p.stats.upstreamErr.Add(1)
		statusCode = http.StatusBadGateway
		http.Error(w, "upstream request failed: "+err.Error(), statusCode)
		log.Printf("proxy_error method=%s path=%s status=%d err=%v dur=%s", r.Method, r.URL.RequestURI(), statusCode, err, time.Since(start))
		return
	}
	defer resp.Body.Close()

	removeHopHeaders(resp.Header)
	copyHeader(w.Header(), resp.Header)
	statusCode = resp.StatusCode
	w.WriteHeader(statusCode)
	n, copyErr := io.Copy(w, resp.Body)
	bytesOut = n
	if copyErr != nil && !errors.Is(copyErr, context.Canceled) {
		p.stats.copyErr.Add(1)
		log.Printf("copy_response_error method=%s path=%s err=%v", r.Method, r.URL.RequestURI(), copyErr)
	}

	if p.accessLog {
		log.Printf(
			"proxied method=%s path=%s status=%d bytes_in=%d bytes_out=%d inflight=%d dur=%s",
			r.Method, r.URL.RequestURI(), statusCode, bytesIn, bytesOut, p.stats.inflight.Load(), time.Since(start),
		)
	}
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

func getenvInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		log.Fatalf("invalid %s=%q: %v", key, v, err)
	}
	return n
}

func getenvBool(key string, fallback bool) bool {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		log.Fatalf("invalid %s=%q: %v", key, v, err)
	}
	return b
}

func getenvDuration(key string, fallback time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		log.Fatalf("invalid %s=%q: %v", key, v, err)
	}
	return d
}
