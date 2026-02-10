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
	"os"
	"strings"
	"sync"
	"time"

	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	awsrdmahttp "github.com/aws/aws-sdk-go-v2/aws/transport/http/rdma"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithy "github.com/aws/smithy-go"
)

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
		autoMkBucket        bool
		enableRDMA          bool
		disableRDMAFallback bool
		rdmaFramePayload    int
		rdmaSendQueueDepth  int
		rdmaRecvQueueDepth  int
		rdmaInlineThreshold int
		rdmaOpenParallelism int
		rdmaOpenInterval    time.Duration
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
	flag.IntVar(&count, "count", 1, "number of operations to execute in this process")
	flag.IntVar(&concurrency, "concurrency", 1, "worker concurrency when -count > 1")
	flag.BoolVar(&autoMkBucket, "ensure-bucket", true, "create bucket if not found")
	flag.BoolVar(&enableRDMA, "rdma", true, "enable SDK RDMA transport dialer")
	flag.BoolVar(&disableRDMAFallback, "rdma-disable-fallback", false, "disable TCP fallback when RDMA open fails")
	flag.IntVar(&rdmaFramePayload, "rdma-frame-payload", 0, "RDMA frame payload bytes (0 uses SDK defaults)")
	flag.IntVar(&rdmaSendQueueDepth, "rdma-sendq", 0, "RDMA send queue depth (0 uses SDK defaults)")
	flag.IntVar(&rdmaRecvQueueDepth, "rdma-recvq", 0, "RDMA recv queue depth (0 uses SDK defaults)")
	flag.IntVar(&rdmaInlineThreshold, "rdma-inline", 0, "RDMA inline threshold bytes (0 uses SDK defaults)")
	flag.IntVar(&rdmaOpenParallelism, "rdma-open-parallelism", awsrdmahttp.DefaultOpenParallelism, "max concurrent RDMA open attempts (0 disables limit)")
	flag.DurationVar(&rdmaOpenInterval, "rdma-open-interval", awsrdmahttp.DefaultOpenMinInterval, "minimum interval between RDMA open attempts (0 disables spacing)")
	flag.Parse()

	if count < 1 {
		log.Fatalf("invalid -count %d, must be >= 1", count)
	}
	if concurrency < 1 {
		log.Fatalf("invalid -concurrency %d, must be >= 1", concurrency)
	}
	if rdmaOpenParallelism < 0 {
		log.Fatalf("invalid -rdma-open-parallelism %d, must be >= 0", rdmaOpenParallelism)
	}
	if rdmaOpenInterval < 0 {
		log.Fatalf("invalid -rdma-open-interval %s, must be >= 0", rdmaOpenInterval)
	}

	accessKey, secretKey, sessionToken, err := loadCredentialsFromEnv()
	if err != nil {
		log.Fatal(err)
	}

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

	closeHTTPClient := func() {
		httpClient.CloseIdleConnections()
	}
	defer closeHTTPClient()

	fail := func(err error) {
		closeHTTPClient()
		log.Fatal(err)
	}
	failf := func(format string, args ...interface{}) {
		closeHTTPClient()
		log.Fatalf(format, args...)
	}

	ctx := context.Background()
	cfg, err := config.LoadDefaultConfig(
		ctx,
		config.WithRegion(region),
		config.WithBaseEndpoint(endpoint),
		config.WithHTTPClient(httpClient),
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(accessKey, secretKey, sessionToken)),
	)
	if err != nil {
		failf("load config failed: %v", err)
	}

	fallbackDial := (&net.Dialer{
		Timeout:   5 * time.Second,
		KeepAlive: 30 * time.Second,
	}).DialContext

	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.UsePathStyle = true
		o.RetryMaxAttempts = 3
		if !enableRDMA {
			return
		}

		rdmaDialer := awsrdmahttp.NewVerbsDialer(awsrdmahttp.VerbsOptions{
			FramePayloadSize: rdmaFramePayload,
			SendQueueDepth:   rdmaSendQueueDepth,
			RecvQueueDepth:   rdmaRecvQueueDepth,
			InlineThreshold:  rdmaInlineThreshold,
		})
		rdmaDialer.OpenParallelism = rdmaOpenParallelism
		rdmaDialer.OpenMinInterval = rdmaOpenInterval
		rdmaDialer.DisableFallback = disableRDMAFallback
		rdmaDialer.FallbackDialContext = fallbackDial

		o.EnableRDMATransport = true
		o.RDMADialer = rdmaDialer
	})

	if enableRDMA {
		log.Printf(
			"RDMA transport enabled fallback=%t frame_payload=%d sendq=%d recvq=%d inline=%d open_parallelism=%d open_interval=%s request_timeout=%s count=%d concurrency=%d",
			!disableRDMAFallback, rdmaFramePayload, rdmaSendQueueDepth, rdmaRecvQueueDepth, rdmaInlineThreshold, rdmaOpenParallelism, rdmaOpenInterval, requestTimeout, count, concurrency,
		)
	} else {
		log.Printf("RDMA transport disabled; using plain TCP HTTP transport request_timeout=%s count=%d concurrency=%d", requestTimeout, count, concurrency)
	}

	if autoMkBucket {
		opCtx, cancel := withOpTimeout(ctx, requestTimeout)
		err := ensureBucket(opCtx, client, bucket)
		cancel()
		if err != nil {
			failf("ensure bucket %q failed: %v", bucket, err)
		}
	}

	switch strings.ToLower(mode) {
	case "put":
		err := runBatch(count, concurrency, func(i int) error {
			opCtx, cancel := withOpTimeout(ctx, requestTimeout)
			defer cancel()
			return runPut(opCtx, client, bucket, batchKey(key, i), putFile, payload)
		})
		if err != nil {
			fail(err)
		}
	case "get":
		err := runBatch(count, concurrency, func(i int) error {
			opCtx, cancel := withOpTimeout(ctx, requestTimeout)
			defer cancel()
			return runGet(opCtx, client, bucket, batchKey(key, i), getOut)
		})
		if err != nil {
			fail(err)
		}
	case "both":
		err := runBatch(count, concurrency, func(i int) error {
			k := batchKey(key, i)

			opCtxPut, cancelPut := withOpTimeout(ctx, requestTimeout)
			putErr := runPut(opCtxPut, client, bucket, k, putFile, payload)
			cancelPut()
			if putErr != nil {
				return putErr
			}

			opCtxGet, cancelGet := withOpTimeout(ctx, requestTimeout)
			getErr := runGet(opCtxGet, client, bucket, k, getOut)
			cancelGet()
			return getErr
		})
		if err != nil {
			fail(err)
		}
	default:
		failf("invalid -mode %q, expected put|get|both", mode)
	}
}

func runPut(ctx context.Context, client *s3.Client, bucket, key, putFile, payload string) error {
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

	_, err = client.PutObject(ctx, input)
	if err != nil {
		return fmt.Errorf("PutObject failed: %w", err)
	}

	log.Printf("PutObject ok bucket=%s key=%s bytes=%d", bucket, key, size)
	return nil
}

func runGet(ctx context.Context, client *s3.Client, bucket, key, outPath string) error {
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

	if outPath != "" {
		log.Printf("GetObject ok bucket=%s key=%s bytes=%d out=%s", bucket, key, n, outPath)
	} else {
		log.Printf("GetObject ok bucket=%s key=%s bytes=%d (stdout)", bucket, key, n)
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

func withOpTimeout(parent context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
	if timeout <= 0 {
		return parent, func() {}
	}
	return context.WithTimeout(parent, timeout)
}

func runBatch(count, concurrency int, fn func(index int) error) error {
	if count == 1 {
		return fn(1)
	}

	jobs := make(chan int)
	errs := make(chan error, count)

	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for idx := range jobs {
				if err := fn(idx); err != nil {
					errs <- fmt.Errorf("op %d failed: %w", idx, err)
				}
			}
		}()
	}

	for i := 1; i <= count; i++ {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	close(errs)

	var firstErr error
	failCount := 0
	for err := range errs {
		if firstErr == nil {
			firstErr = err
		}
		failCount++
	}

	if failCount > 0 {
		return fmt.Errorf("batch finished with %d/%d failures: %w", failCount, count, firstErr)
	}

	log.Printf("batch finished successfully count=%d concurrency=%d", count, concurrency)
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
