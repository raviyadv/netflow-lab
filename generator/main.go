// Generates NetFlow-style JSON-lines files and uploads them to s3://<bucket>/raw/.
// Normal traffic for N devices, plus injected anomalies we can verify later:
//
//	every 4th batch: traffic spike on router-7  (huge byte counts)
//	every 5th batch: port scan from router-3    (150 distinct destination ports)
//
// Run: go run . -bucket netflow-lab-raw-<account-id> -batches 10
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/rand/v2"
	"sort"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

const tsLayout = "2006-01-02 15:04:05.000" // format Flink SQL reads as TIMESTAMP(3)

var commonPorts = []int{443, 80, 53, 22, 8080}

type Event struct {
	DeviceID  string    `json:"device_id"`
	SrcIP     string    `json:"src_ip"`
	DstIP     string    `json:"dst_ip"`
	DstPort   int       `json:"dst_port"`
	Protocol  string    `json:"protocol"`
	Bytes     int64     `json:"bytes"`
	EventTime string    `json:"event_time"`
	ts        time.Time // used for sorting only, not written to JSON
}

func main() {
	bucket := flag.String("bucket", "", "S3 bucket name (required)")
	devices := flag.Int("devices", 10, "number of devices sending traffic")
	interval := flag.Duration("interval", 30*time.Second, "time span of each file and pause between uploads")
	batches := flag.Int("batches", 10, "files to upload (0 = run until Ctrl+C)")
	flag.Parse()
	if *bucket == "" {
		log.Fatal("-bucket is required")
	}

	ctx := context.Background()
	cfg, err := config.LoadDefaultConfig(ctx) // same credentials/region as the AWS CLI
	if err != nil {
		log.Fatalf("aws config: %v", err)
	}
	client := s3.NewFromConfig(cfg)

	for i := 1; *batches == 0 || i <= *batches; i++ {
		end := time.Now().UTC()
		start := end.Add(-*interval)

		events := normalTraffic(*devices, start, *interval)
		note := ""
		if i%4 == 0 {
			events = append(events, trafficSpike("router-7", start, *interval)...)
			note += "  +SPIKE(router-7)"
		}
		if i%5 == 0 {
			events = append(events, portScan("router-3", start, *interval)...)
			note += "  +PORTSCAN(router-3)"
		}

		// Sort by event time so Flink's watermark only moves forward
		sort.Slice(events, func(a, b int) bool { return events[a].ts.Before(events[b].ts) })

		var buf bytes.Buffer
		enc := json.NewEncoder(&buf) // Encode writes one JSON object + newline = JSON lines
		for _, e := range events {
			if err := enc.Encode(e); err != nil {
				log.Fatalf("encode: %v", err)
			}
		}

		key := fmt.Sprintf("raw/netflow-%s.jsonl", end.Format("20060102-150405"))
		_, err := client.PutObject(ctx, &s3.PutObjectInput{
			Bucket: aws.String(*bucket),
			Key:    aws.String(key),
			Body:   bytes.NewReader(buf.Bytes()),
		})
		if err != nil {
			log.Fatalf("upload %s: %v", key, err)
		}
		log.Printf("batch %d: uploaded %s (%d events)%s", i, key, len(events), note)

		if *batches == 0 || i < *batches {
			time.Sleep(*interval)
		}
	}
}

// ~1 event per device per second, small byte counts, a handful of common ports.
func normalTraffic(devices int, start time.Time, span time.Duration) []Event {
	var out []Event
	for d := 1; d <= devices; d++ {
		id := fmt.Sprintf("router-%d", d)
		for s := 0; s < int(span.Seconds()); s++ {
			t := start.Add(time.Duration(s)*time.Second + jitter())
			port := commonPorts[rand.IntN(len(commonPorts))]
			out = append(out, newEvent(id, t, port, 200+rand.Int64N(1300)))
		}
	}
	return out
}

// 200 very large transfers in one window -> total bytes far above the threshold.
func trafficSpike(device string, start time.Time, span time.Duration) []Event {
	var out []Event
	for n := 0; n < 200; n++ {
		t := start.Add(time.Duration(rand.Int64N(int64(span))))
		out = append(out, newEvent(device, t, 443, 20_000+rand.Int64N(30_000)))
	}
	return out
}

// One device touching 150 different ports with tiny packets.
func portScan(device string, start time.Time, span time.Duration) []Event {
	var out []Event
	for port := 1; port <= 150; port++ {
		t := start.Add(time.Duration(rand.Int64N(int64(span))))
		out = append(out, newEvent(device, t, port, 60))
	}
	return out
}

func newEvent(device string, t time.Time, port int, bytes int64) Event {
	proto := "TCP"
	if port == 53 {
		proto = "UDP"
	}
	return Event{
		DeviceID:  device,
		SrcIP:     fmt.Sprintf("10.0.0.%d", 1+rand.IntN(254)),
		DstIP:     fmt.Sprintf("172.16.%d.%d", rand.IntN(256), 1+rand.IntN(254)),
		DstPort:   port,
		Protocol:  proto,
		Bytes:     bytes,
		EventTime: t.Format(tsLayout),
		ts:        t,
	}
}

func jitter() time.Duration {
	return time.Duration(rand.IntN(1000)) * time.Millisecond
}
