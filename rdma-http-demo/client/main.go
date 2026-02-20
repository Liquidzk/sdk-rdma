package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptrace"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	awsrdmahttp "github.com/aws/aws-sdk-go-v2/aws/transport/http/rdma"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithy "github.com/aws/smithy-go"
)

type connTraceStats struct {
	gotConnTotal   atomic.Int64
	gotConnReused  atomic.Int64
	gotConnNew     atomic.Int64
	gotConnWasIdle atomic.Int64

	rdmaOpenCalls   atomic.Int64
	rdmaOpenSuccess atomic.Int64
	rdmaOpenFailed  atomic.Int64
}

func withConnTrace(ctx context.Context, stats *connTraceStats) context.Context {
	if stats == nil {
		return ctx
	}

	trace := &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			stats.gotConnTotal.Add(1)
			if info.Reused {
				stats.gotConnReused.Add(1)
			} else {
				stats.gotConnNew.Add(1)
			}
			if info.WasIdle {
				stats.gotConnWasIdle.Add(1)
			}
		},
	}
	return httptrace.WithClientTrace(ctx, trace)
}

func (s *connTraceStats) logSummary(enableRDMA bool) {
	if s == nil {
		return
	}

	gotTotal := s.gotConnTotal.Load()
	gotReused := s.gotConnReused.Load()
	gotNew := s.gotConnNew.Load()
	gotWasIdle := s.gotConnWasIdle.Load()

	reusePct := 0.0
	if gotTotal > 0 {
		reusePct = (float64(gotReused) * 100.0) / float64(gotTotal)
	}

	if enableRDMA {
		log.Printf(
			"conn trace got_conn_total=%d got_conn_reused=%d got_conn_new=%d got_conn_was_idle=%d reuse_pct=%.2f rdma_open_calls=%d rdma_open_success=%d rdma_open_failed=%d",
			gotTotal,
			gotReused,
			gotNew,
			gotWasIdle,
			reusePct,
			s.rdmaOpenCalls.Load(),
			s.rdmaOpenSuccess.Load(),
			s.rdmaOpenFailed.Load(),
		)
		return
	}

	log.Printf(
		"conn trace got_conn_total=%d got_conn_reused=%d got_conn_new=%d got_conn_was_idle=%d reuse_pct=%.2f",
		gotTotal,
		gotReused,
		gotNew,
		gotWasIdle,
		reusePct,
	)
}

func main() {
	var (
		endpoint            string
		region              string
		bucket              string
		key                 string
		mode                string
		putFile             string
		payload             string
		getOut              string
		requestTimeout      time.Duration
		count               int
		concurrency         int
		targetRPS           float64
		runDuration         time.Duration
		autoMkBucket        bool
		enableRDMA          bool
		disableRDMAFallback bool
		rdmaFramePayload    int
		rdmaSendQueueDepth  int
		rdmaRecvQueueDepth  int
		rdmaInlineThreshold int
		rdmaLowCPU          bool
		rdmaSendSignalIntvl int
		rdmaOpenParallelism int
		rdmaOpenInterval    time.Duration
		clientPoolSize      int
		retryMaxAttempts    int
		enableConnTrace     bool
		logEachRequest      bool
	)

	flag.StringVar(&endpoint, "endpoint", getenv("S3_PROXY_ENDPOINT", "http://127.0.0.1:18080"), "S3 base endpoint (relay server)")
	flag.StringVar(&region, "region", getenv("AWS_REGION", "us-east-1"), "AWS region")
	flag.StringVar(&bucket, "bucket", getenv("S3_BUCKET", "rdma-demo"), "bucket name")
	flag.StringVar(&key, "key", getenv("S3_KEY", "hello.txt"), "object key")
	flag.StringVar(&mode, "mode", "both", "operation mode: put|get|both")
	flag.StringVar(&putFile, "put-file", "", "upload from local file instead of -payload")
	flag.StringVar(&payload, "payload", "hello from rdma-http-demo", "payload when -put-file is empty")
	flag.StringVar(&getOut, "get-out", "", "write GetObject response to file (default stdout)")
	flag.DurationVar(&requestTimeout, "request-timeout", 30*time.Second, "timeout for each S3 API call (0 disables timeout)")
	flag.IntVar(&count, "count", 1, "number of operations to execute in this process (ignored when -run-duration > 0)")
	flag.IntVar(&concurrency, "concurrency", 1, "worker concurrency limit; 0 means no in-flight cap")
	flag.Float64Var(&targetRPS, "target-rps", getenvFloat("TARGET_RPS", 0), "target request start rate (requests per second); <=0 disables pacing")
	flag.DurationVar(&runDuration, "run-duration", getenvDuration("RUN_DURATION", 0), "total batch run duration; >0 drives request count from time")
	flag.BoolVar(&autoMkBucket, "ensure-bucket", true, "create bucket if not found")
	flag.BoolVar(&enableRDMA, "rdma", true, "enable SDK RDMA transport dialer")
	flag.BoolVar(&disableRDMAFallback, "rdma-disable-fallback", false, "disable TCP fallback when RDMA open fails")
	flag.IntVar(&rdmaFramePayload, "rdma-frame-payload", 0, "RDMA frame payload bytes (0 uses SDK defaults)")
	flag.IntVar(&rdmaSendQueueDepth, "rdma-sendq", 0, "RDMA send queue depth (0 uses SDK defaults)")
	flag.IntVar(&rdmaRecvQueueDepth, "rdma-recvq", 0, "RDMA recv queue depth (0 uses SDK defaults)")
	flag.IntVar(&rdmaInlineThreshold, "rdma-inline", 0, "RDMA inline threshold bytes (0 uses SDK defaults)")
	flag.BoolVar(&rdmaLowCPU, "rdma-low-cpu", getenvBool("RDMA_LOW_CPU", true), "favor lower CPU usage over latency/throughput in RDMA transport")
	flag.IntVar(&rdmaSendSignalIntvl, "rdma-send-signal-interval", getenvInt("RDMA_SEND_SIGNAL_INTERVAL", 0), "RDMA send completion signal interval (0 uses SDK defaults)")
	flag.IntVar(&rdmaOpenParallelism, "rdma-open-parallelism", getenvInt("RDMA_OPEN_PARALLELISM", 0), "max concurrent RDMA open attempts (0 disables limit)")
	flag.DurationVar(&rdmaOpenInterval, "rdma-open-interval", awsrdmahttp.DefaultOpenMinInterval, "minimum interval between RDMA open attempts (0 disables spacing)")
	flag.IntVar(&clientPoolSize, "client-pool-size", getenvInt("S3_CLIENT_POOL_SIZE", 1), "number of independent s3 clients/transports to spread workload across")
	flag.IntVar(&retryMaxAttempts, "retry-max-attempts", getenvInt("S3_RETRY_MAX_ATTEMPTS", 3), "max S3 retry attempts per request (>=1)")
	flag.BoolVar(&enableConnTrace, "conn-trace", getenvBool("CONN_TRACE", false), "enable connection trace counters (adds per-request overhead)")
	flag.BoolVar(&logEachRequest, "log-each-request", getenvBool("LOG_EACH_REQUEST", false), "log each successful request (adds CPU overhead)")
	flag.Parse()

	if count < 0 {
		log.Fatalf("invalid -count %d, must be >= 0", count)
	}
	if concurrency < 0 {
		log.Fatalf("invalid -concurrency %d, must be >= 0", concurrency)
	}
	if targetRPS < 0 {
		log.Fatalf("invalid -target-rps %v, must be >= 0", targetRPS)
	}
	if runDuration < 0 {
		log.Fatalf("invalid -run-duration %s, must be >= 0", runDuration)
	}
	if runDuration > 0 && targetRPS <= 0 {
		log.Fatalf("invalid configuration: -run-duration requires -target-rps > 0")
	}
	if runDuration <= 0 && count < 1 {
		log.Fatalf("invalid configuration: set -count >= 1, or set -run-duration > 0")
	}
	if rdmaOpenParallelism < 0 {
		log.Fatalf("invalid -rdma-open-parallelism %d, must be >= 0", rdmaOpenParallelism)
	}
	if rdmaSendSignalIntvl < 0 {
		log.Fatalf("invalid -rdma-send-signal-interval %d, must be >= 0", rdmaSendSignalIntvl)
	}
	if rdmaOpenInterval < 0 {
		log.Fatalf("invalid -rdma-open-interval %s, must be >= 0", rdmaOpenInterval)
	}
	if clientPoolSize < 1 {
		log.Fatalf("invalid -client-pool-size %d, must be >= 1", clientPoolSize)
	}
	if retryMaxAttempts < 1 {
		log.Fatalf("invalid -retry-max-attempts %d, must be >= 1", retryMaxAttempts)
	}

	accessKey, secretKey, sessionToken, err := loadCredentialsFromEnv()
	if err != nil {
		log.Fatal(err)
	}

	var connStats *connTraceStats
	if enableConnTrace {
		connStats = &connTraceStats{}
	}
	var logConnStatsOnce sync.Once
	logConnStats := func() {
		if connStats == nil {
			return
		}
		logConnStatsOnce.Do(func() {
			connStats.logSummary(enableRDMA)
		})
	}

	fail := func(err error) {
		logConnStats()
		log.Fatal(err)
	}
	failf := func(format string, args ...interface{}) {
		logConnStats()
		log.Fatalf(format, args...)
	}

	ctx := context.Background()
	cfg, err := config.LoadDefaultConfig(
		ctx,
		config.WithRegion(region),
		config.WithBaseEndpoint(endpoint),
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(accessKey, secretKey, sessionToken)),
	)
	if err != nil {
		failf("load config failed: %v", err)
	}

	fallbackDial := (&net.Dialer{
		Timeout:   5 * time.Second,
		KeepAlive: 30 * time.Second,
	}).DialContext

	newHTTPClient := func() *awshttp.BuildableClient {
		httpClient := awshttp.NewBuildableClient().WithTransportOptions(func(tr *http.Transport) {
			tr.Proxy = http.ProxyFromEnvironment
			tr.MaxIdleConns = 512
			tr.MaxIdleConnsPerHost = 256
			tr.IdleConnTimeout = 90 * time.Second
			tr.ExpectContinueTimeout = 1 * time.Second
			tr.ForceAttemptHTTP2 = false
		})
		if requestTimeout > 0 {
			httpClient = httpClient.WithTimeout(requestTimeout)
		}
		return httpClient
	}

	newS3Client := func(httpClient *awshttp.BuildableClient) *s3.Client {
		return s3.NewFromConfig(cfg, func(o *s3.Options) {
			o.HTTPClient = httpClient
			o.UsePathStyle = true
			o.RetryMaxAttempts = retryMaxAttempts
			if !enableRDMA {
				return
			}

			rdmaDialer := awsrdmahttp.NewVerbsDialer(awsrdmahttp.VerbsOptions{
				FramePayloadSize:   rdmaFramePayload,
				SendQueueDepth:     rdmaSendQueueDepth,
				RecvQueueDepth:     rdmaRecvQueueDepth,
				InlineThreshold:    rdmaInlineThreshold,
				LowCPU:             rdmaLowCPU,
				SendSignalInterval: rdmaSendSignalIntvl,
			})
			rdmaDialer.OpenParallelism = rdmaOpenParallelism
			rdmaDialer.OpenMinInterval = rdmaOpenInterval
			rdmaDialer.DisableFallback = disableRDMAFallback
			rdmaDialer.FallbackDialContext = fallbackDial
			if connStats != nil && rdmaDialer.Open != nil {
				baseOpen := rdmaDialer.Open
				rdmaDialer.Open = func(ctx context.Context, network, address string) (awsrdmahttp.MessageConn, error) {
					connStats.rdmaOpenCalls.Add(1)
					conn, err := baseOpen(ctx, network, address)
					if err != nil {
						connStats.rdmaOpenFailed.Add(1)
					} else {
						connStats.rdmaOpenSuccess.Add(1)
					}
					return conn, err
				}
			}

			o.EnableRDMATransport = true
			o.RDMADialer = rdmaDialer
		})
	}

	httpClients := make([]*awshttp.BuildableClient, 0, clientPoolSize)
	clients := make([]*s3.Client, 0, clientPoolSize)
	for i := 0; i < clientPoolSize; i++ {
		httpClient := newHTTPClient()
		httpClients = append(httpClients, httpClient)
		clients = append(clients, newS3Client(httpClient))
	}
	defer func() {
		for _, hc := range httpClients {
			hc.CloseIdleConnections()
		}
	}()

	if enableRDMA {
		log.Printf(
			"RDMA transport enabled fallback=%t frame_payload=%d sendq=%d recvq=%d inline=%d low_cpu=%t send_signal_interval=%d open_parallelism=%d open_interval=%s request_timeout=%s retry_max_attempts=%d count=%d concurrency=%d target_rps=%.2f run_duration=%s client_pool=%d conn_trace=%t log_each_request=%t",
			!disableRDMAFallback, rdmaFramePayload, rdmaSendQueueDepth, rdmaRecvQueueDepth, rdmaInlineThreshold, rdmaLowCPU, rdmaSendSignalIntvl, rdmaOpenParallelism, rdmaOpenInterval, requestTimeout, retryMaxAttempts, count, concurrency, targetRPS, runDuration, clientPoolSize, enableConnTrace, logEachRequest,
		)
	} else {
		log.Printf("RDMA transport disabled; using plain TCP HTTP transport request_timeout=%s retry_max_attempts=%d count=%d concurrency=%d target_rps=%.2f run_duration=%s client_pool=%d conn_trace=%t log_each_request=%t", requestTimeout, retryMaxAttempts, count, concurrency, targetRPS, runDuration, clientPoolSize, enableConnTrace, logEachRequest)
	}

	if autoMkBucket {
		opCtx, cancel := withOpTimeout(ctx, requestTimeout)
		err := ensureBucket(opCtx, clients[0], bucket)
		cancel()
		if err != nil {
			failf("ensure bucket %q failed: %v", bucket, err)
		}
	}

	switch strings.ToLower(mode) {
	case "put":
		err := runBatch(batchOptions{
			Count:       count,
			Concurrency: concurrency,
			TargetRPS:   targetRPS,
			Duration:    runDuration,
		}, func(worker, i int) error {
			opCtx, cancel := withOpTimeout(ctx, requestTimeout)
			defer cancel()
			return runPut(opCtx, clients[worker%len(clients)], bucket, batchKey(key, i), putFile, payload, connStats, logEachRequest)
		})
		if err != nil {
			fail(err)
		}
	case "get":
		err := runBatch(batchOptions{
			Count:       count,
			Concurrency: concurrency,
			TargetRPS:   targetRPS,
			Duration:    runDuration,
		}, func(worker, i int) error {
			opCtx, cancel := withOpTimeout(ctx, requestTimeout)
			defer cancel()
			return runGet(opCtx, clients[worker%len(clients)], bucket, batchKey(key, i), getOut, connStats, logEachRequest)
		})
		if err != nil {
			fail(err)
		}
	case "both":
		err := runBatch(batchOptions{
			Count:       count,
			Concurrency: concurrency,
			TargetRPS:   targetRPS,
			Duration:    runDuration,
		}, func(worker, i int) error {
			client := clients[worker%len(clients)]
			k := batchKey(key, i)

			opCtxPut, cancelPut := withOpTimeout(ctx, requestTimeout)
			putErr := runPut(opCtxPut, client, bucket, k, putFile, payload, connStats, logEachRequest)
			cancelPut()
			if putErr != nil {
				return putErr
			}

			opCtxGet, cancelGet := withOpTimeout(ctx, requestTimeout)
			getErr := runGet(opCtxGet, client, bucket, k, getOut, connStats, logEachRequest)
			cancelGet()
			return getErr
		})
		if err != nil {
			fail(err)
		}
	default:
		failf("invalid -mode %q, expected put|get|both", mode)
	}

	logConnStats()
}

func runPut(ctx context.Context, client *s3.Client, bucket, key, putFile, payload string, connStats *connTraceStats, logEachRequest bool) error {
	body, closer, size, err := openPutBody(putFile, payload)
	if err != nil {
		return fmt.Errorf("prepare put body: %w", err)
	}
	if closer != nil {
		defer closer.Close()
	}

	input := &s3.PutObjectInput{
		Bucket: &bucket,
		Key:    &key,
		Body:   body,
	}
	if size >= 0 {
		input.ContentLength = &size
	}

	ctx = withConnTrace(ctx, connStats)
	_, err = client.PutObject(ctx, input)
	if err != nil {
		return fmt.Errorf("PutObject failed: %w", err)
	}

	if logEachRequest {
		log.Printf("PutObject ok bucket=%s key=%s bytes=%d", bucket, key, size)
	}
	return nil
}

func runGet(ctx context.Context, client *s3.Client, bucket, key, outPath string, connStats *connTraceStats, logEachRequest bool) error {
	ctx = withConnTrace(ctx, connStats)
	resp, err := client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: &bucket,
		Key:    &key,
	})
	if err != nil {
		return fmt.Errorf("GetObject failed: %w", err)
	}
	defer resp.Body.Close()

	writer := io.Writer(os.Stdout)
	var outFile *os.File
	if outPath != "" {
		outFile, err = os.Create(outPath)
		if err != nil {
			return fmt.Errorf("create output file: %w", err)
		}
		defer outFile.Close()
		writer = outFile
	}

	n, err := io.Copy(writer, resp.Body)
	if err != nil {
		return fmt.Errorf("read object body: %w", err)
	}

	if logEachRequest {
		if outPath != "" {
			log.Printf("GetObject ok bucket=%s key=%s bytes=%d out=%s", bucket, key, n, outPath)
		} else {
			log.Printf("GetObject ok bucket=%s key=%s bytes=%d (stdout)", bucket, key, n)
		}
	}
	return nil
}

func ensureBucket(ctx context.Context, client *s3.Client, bucket string) error {
	_, err := client.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: &bucket})
	if err == nil {
		return nil
	}

	log.Printf("bucket %q not ready (head failed), trying create", bucket)
	_, err = client.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: &bucket})
	if err == nil {
		return nil
	}

	var apiErr smithy.APIError
	if errors.As(err, &apiErr) {
		code := apiErr.ErrorCode()
		if code == "BucketAlreadyOwnedByYou" || code == "BucketAlreadyExists" {
			return nil
		}
	}
	return err
}

func openPutBody(putFile, payload string) (io.Reader, io.Closer, int64, error) {
	if putFile == "" {
		b := []byte(payload)
		return bytes.NewReader(b), nil, int64(len(b)), nil
	}

	f, err := os.Open(putFile)
	if err != nil {
		return nil, nil, -1, err
	}

	st, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, nil, -1, err
	}

	return f, f, st.Size(), nil
}

func loadCredentialsFromEnv() (accessKey, secretKey, sessionToken string, err error) {
	accessKey = firstNonEmpty(
		os.Getenv("AWS_ACCESS_KEY_ID"),
		os.Getenv("MINIO_ROOT_USER"),
	)
	secretKey = firstNonEmpty(
		os.Getenv("AWS_SECRET_ACCESS_KEY"),
		os.Getenv("MINIO_ROOT_PASSWORD"),
	)
	sessionToken = os.Getenv("AWS_SESSION_TOKEN")

	if accessKey == "" || secretKey == "" {
		return "", "", "", fmt.Errorf("missing credentials: set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (or MINIO_ROOT_USER/MINIO_ROOT_PASSWORD)")
	}
	return accessKey, secretKey, sessionToken, nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
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
	v := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	if v == "" {
		return fallback
	}
	switch v {
	case "1", "true", "t", "yes", "y", "on":
		return true
	case "0", "false", "f", "no", "n", "off":
		return false
	default:
		log.Fatalf("invalid %s=%q: expected boolean", key, os.Getenv(key))
		return fallback
	}
}

func getenvFloat(key string, fallback float64) float64 {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.ParseFloat(v, 64)
	if err != nil {
		log.Fatalf("invalid %s=%q: %v", key, v, err)
	}
	return n
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

func withOpTimeout(parent context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
	if timeout <= 0 {
		return parent, func() {}
	}
	return context.WithTimeout(parent, timeout)
}

type batchOptions struct {
	Count       int
	Concurrency int
	TargetRPS   float64
	Duration    time.Duration
}

func runBatch(opts batchOptions, fn func(worker, index int) error) error {
	count := opts.Count
	concurrency := opts.Concurrency
	targetRPS := opts.TargetRPS
	runDuration := opts.Duration

	if runDuration <= 0 && count < 1 {
		return fmt.Errorf("invalid batch options: count=%d run_duration=%s", count, runDuration)
	}
	if runDuration > 0 && targetRPS <= 0 {
		return fmt.Errorf("invalid batch options: run_duration requires target_rps > 0")
	}

	var (
		mu       sync.Mutex
		firstErr error
		failCnt  int
	)
	recordErr := func(idx int, err error) {
		if err == nil {
			return
		}
		mu.Lock()
		defer mu.Unlock()
		failCnt++
		if firstErr == nil {
			firstErr = fmt.Errorf("op %d failed: %w", idx, err)
		}
	}

	dispatchCount := 0
	dispatch := func(submit func(idx int)) {
		if runDuration > 0 {
			interval := time.Duration(float64(time.Second) / targetRPS)
			if interval < time.Nanosecond {
				interval = time.Nanosecond
			}
			ticker := time.NewTicker(interval)
			defer ticker.Stop()

			deadline := time.Now().Add(runDuration)
			for idx := 1; ; idx++ {
				now := time.Now()
				if now.After(deadline) {
					break
				}
				submit(idx)
				dispatchCount++
				<-ticker.C
			}
			return
		}

		if targetRPS > 0 {
			interval := time.Duration(float64(time.Second) / targetRPS)
			if interval < time.Nanosecond {
				interval = time.Nanosecond
			}
			ticker := time.NewTicker(interval)
			defer ticker.Stop()

			for idx := 1; idx <= count; idx++ {
				if idx > 1 {
					<-ticker.C
				}
				submit(idx)
				dispatchCount++
			}
			return
		}

		for idx := 1; idx <= count; idx++ {
			submit(idx)
			dispatchCount++
		}
	}

	var wg sync.WaitGroup
	if concurrency > 0 {
		jobs := make(chan int, maxInt(2, concurrency*2))
		for i := 0; i < concurrency; i++ {
			workerID := i
			wg.Add(1)
			go func() {
				defer wg.Done()
				for idx := range jobs {
					if err := fn(workerID, idx); err != nil {
						recordErr(idx, err)
					}
				}
			}()
		}

		dispatch(func(idx int) {
			jobs <- idx
		})
		close(jobs)
		wg.Wait()
	} else {
		dispatch(func(idx int) {
			workerID := idx - 1
			wg.Add(1)
			go func() {
				defer wg.Done()
				if err := fn(workerID, idx); err != nil {
					recordErr(idx, err)
				}
			}()
		})
		wg.Wait()
	}

	successCnt := dispatchCount - failCnt
	log.Printf(
		"batch summary total=%d success=%d failed=%d concurrency_limit=%d target_rps=%.2f run_duration=%s",
		dispatchCount, successCnt, failCnt, concurrency, targetRPS, runDuration,
	)

	if failCnt > 0 {
		return fmt.Errorf("batch finished with %d/%d failures: %w", failCnt, dispatchCount, firstErr)
	}
	return nil
}

func batchKey(base string, index int) string {
	if index <= 1 {
		return base
	}

	dot := strings.LastIndex(base, ".")
	slash := strings.LastIndex(base, "/")
	if dot > slash {
		return fmt.Sprintf("%s-%d%s", base[:dot], index, base[dot:])
	}
	return fmt.Sprintf("%s-%d", base, index)
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
