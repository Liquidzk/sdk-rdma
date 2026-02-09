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
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	smithy "github.com/aws/smithy-go"
)

// RDMAHTTPClient is the transport hook point. Replace DialContext with your RDMA-backed dialer.
type RDMAHTTPClient struct {
	inner *http.Client
}

func (c *RDMAHTTPClient) Do(req *http.Request) (*http.Response, error) {
	return c.inner.Do(req)
}

func main() {
	var (
		endpoint     string
		region       string
		bucket       string
		key          string
		mode         string
		putFile      string
		payload      string
		getOut       string
		autoMkBucket bool
	)

	flag.StringVar(&endpoint, "endpoint", getenv("S3_PROXY_ENDPOINT", "http://127.0.0.1:18080"), "S3 base endpoint (relay server)")
	flag.StringVar(&region, "region", getenv("AWS_REGION", "us-east-1"), "AWS region")
	flag.StringVar(&bucket, "bucket", getenv("S3_BUCKET", "rdma-demo"), "bucket name")
	flag.StringVar(&key, "key", getenv("S3_KEY", "hello.txt"), "object key")
	flag.StringVar(&mode, "mode", "both", "operation mode: put|get|both")
	flag.StringVar(&putFile, "put-file", "", "upload from local file instead of -payload")
	flag.StringVar(&payload, "payload", "hello from rdma-http-demo", "payload when -put-file is empty")
	flag.StringVar(&getOut, "get-out", "", "write GetObject response to file (default stdout)")
	flag.BoolVar(&autoMkBucket, "ensure-bucket", true, "create bucket if not found")
	flag.Parse()

	accessKey, secretKey, sessionToken, err := loadCredentialsFromEnv()
	if err != nil {
		log.Fatal(err)
	}

	rdmaDial := (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}).DialContext
	httpClient := &RDMAHTTPClient{
		inner: &http.Client{
			Transport: &http.Transport{
				Proxy:                 http.ProxyFromEnvironment,
				DialContext:           rdmaDial,
				MaxIdleConns:          512,
				MaxIdleConnsPerHost:   256,
				IdleConnTimeout:       90 * time.Second,
				ExpectContinueTimeout: 1 * time.Second,
				ForceAttemptHTTP2:     false,
			},
		},
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
		log.Fatalf("load config failed: %v", err)
	}

	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.UsePathStyle = true
		o.RetryMaxAttempts = 3
	})

	if autoMkBucket {
		if err := ensureBucket(ctx, client, bucket); err != nil {
			log.Fatalf("ensure bucket %q failed: %v", bucket, err)
		}
	}

	switch strings.ToLower(mode) {
	case "put":
		if err := runPut(ctx, client, bucket, key, putFile, payload); err != nil {
			log.Fatal(err)
		}
	case "get":
		if err := runGet(ctx, client, bucket, key, getOut); err != nil {
			log.Fatal(err)
		}
	case "both":
		if err := runPut(ctx, client, bucket, key, putFile, payload); err != nil {
			log.Fatal(err)
		}
		if err := runGet(ctx, client, bucket, key, getOut); err != nil {
			log.Fatal(err)
		}
	default:
		log.Fatalf("invalid -mode %q, expected put|get|both", mode)
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
