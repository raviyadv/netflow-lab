// Lambda: S3 (JSON lines) -> Kafka topic "network-events", keyed by device_id.
// Build:  GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -tags lambda.norpc -o bootstrap main.go
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/twmb/franz-go/pkg/kgo"
)

const batchSize = 500

var (
	s3Client *s3.Client
	kafka    *kgo.Client
)

type netEvent struct {
	DeviceID string `json:"device_id"`
}

// init runs once per cold start; clients are reused across invocations.
func init() {
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatalf("aws config: %v", err)
	}
	s3Client = s3.NewFromConfig(cfg)

	topic := os.Getenv("KAFKA_TOPIC")
	if topic == "" {
		topic = "network-events"
	}
	kafka, err = kgo.NewClient(
		kgo.SeedBrokers(strings.Split(os.Getenv("KAFKA_BROKERS"), ",")...),
		kgo.DefaultProduceTopic(topic),
		kgo.ProducerLinger(5*time.Millisecond),
		// franz-go producers are idempotent by default.
	)
	if err != nil {
		log.Fatalf("kafka client: %v", err)
	}
}

func handler(ctx context.Context, e events.S3Event) error {
	for _, rec := range e.Records {
		bucket, key := rec.S3.Bucket.Name, rec.S3.Object.URLDecodedKey
		if err := processObject(ctx, bucket, key); err != nil {
			return fmt.Errorf("s3://%s/%s: %w", bucket, key, err) // error -> Lambda retries
		}
	}
	return nil
}

func processObject(ctx context.Context, bucket, key string) error {
	obj, err := s3Client.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(bucket), Key: aws.String(key)})
	if err != nil {
		return fmt.Errorf("get object: %w", err)
	}
	defer obj.Body.Close()

	sc := bufio.NewScanner(obj.Body) // streams the file; never loads it all into memory
	sc.Buffer(make([]byte, 64*1024), 1024*1024)

	batch := make([]*kgo.Record, 0, batchSize)
	sent, skipped := 0, 0

	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		if err := kafka.ProduceSync(ctx, batch...).FirstErr(); err != nil {
			return fmt.Errorf("produce: %w", err)
		}
		sent += len(batch)
		batch = batch[:0]
		return nil
	}

	for sc.Scan() {
		line := append([]byte(nil), sc.Bytes()...) // copy: Scanner reuses its buffer
		var ev netEvent
		if err := json.Unmarshal(line, &ev); err != nil || ev.DeviceID == "" {
			skipped++ // bad record: skip (production: send to a DLQ topic)
			continue
		}
		batch = append(batch, &kgo.Record{Key: []byte(ev.DeviceID), Value: line})
		if len(batch) == batchSize {
			if err := flush(); err != nil {
				return err
			}
		}
	}
	if err := sc.Err(); err != nil {
		return fmt.Errorf("read: %w", err)
	}
	if err := flush(); err != nil {
		return err
	}

	log.Printf("s3://%s/%s sent=%d skipped=%d", bucket, key, sent, skipped)
	return nil
}

func main() {
	lambda.Start(handler)
}