package main

import (
	"database/sql"
	"flag"
	"fmt"
	"io"
	"math"
	"math/rand/v2"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	_ "github.com/lib/pq"
)

const (
	defaultDBURI           = "postgres://postgres:postgres@open-webui-rw.llm.svc.cluster.local:5432/openwebui?sslmode=require"
	defaultAPIBase         = "http://open-webui.llm.svc.cluster.local:8080"
	defaultBatchSize       = 500
	defaultConcurrency     = 1
	defaultMaxRetries      = 1
	defaultRetryDelay      = 5.0
	defaultClientTimeout   = 30 * time.Second
	defaultRateLimitDelay  = 5 * time.Second
)

func main() {
	dryRun := flag.Bool("dry-run", false, "show what would be deleted without deleting")
	dbURI := flag.String("db-uri", os.Getenv("DATABASE_URL"), "PostgreSQL connection URI")
	apiToken := flag.String("api-token", os.Getenv("OWUI_API_TOKEN"), "Open WebUI API bearer token")
	concurrency := flag.Int("concurrency", defaultConcurrency, "number of concurrent API deletes")
	batchSize := flag.Int("batch-size", defaultBatchSize, "number of file IDs to fetch per query")
	apiBase := flag.String("api-base", os.Getenv("OWUI_API_BASE"), "Open WebUI API base URL")
	maxRetries := flag.Int("max-retries", defaultMaxRetries, "max HTTP retries per request")
	retryDelay := flag.Float64("retry-delay", defaultRetryDelay, "base delay in seconds for exponential backoff")
	flag.Parse()

	if *dbURI == "" {
		fmt.Fprintln(os.Stderr, "Error: DATABASE_URL is required")
		os.Exit(1)
	}
	if *apiToken == "" {
		fmt.Fprintln(os.Stderr, "Error: OWUI_API_TOKEN is required")
		os.Exit(1)
	}
	if *apiBase == "" {
		*apiBase = defaultAPIBase
	}
	if *batchSize <= 0 {
		fmt.Fprintln(os.Stderr, "Error: batch-size must be positive")
		os.Exit(1)
	}
	if *maxRetries < 0 {
		fmt.Fprintln(os.Stderr, "Error: max-retries must be non-negative")
		os.Exit(1)
	}
	if *retryDelay <= 0 {
		fmt.Fprintln(os.Stderr, "Error: retry-delay must be positive")
		os.Exit(1)
	}

	db, err := sql.Open("postgres", *dbURI)
	if err != nil {
		fmt.Fprintf(os.Stderr, "DB open: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		fmt.Fprintf(os.Stderr, "DB ping: %v\n", err)
		os.Exit(1)
	}

	fileIDs, err := getOrphanedFileIDs(db, *batchSize)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Query error: %v\n", err)
		os.Exit(1)
	}

	if len(fileIDs) == 0 {
		fmt.Println("No orphaned files found. Nothing to do.")
		return
	}

	fmt.Printf("Found %d orphaned files.\n\n", len(fileIDs))

	deleted, failed := cleanup(fileIDs, *apiBase, *apiToken, *concurrency, *maxRetries, *retryDelay, *dryRun)
	fmt.Printf("Deleted: %d\nFailed: %d\n", deleted, failed)
}

func getOrphanedFileIDs(db *sql.DB, batchSize int) ([]string, error) {
	var allIDs []string

	for {
		batch, err := fetchBatch(db, batchSize, len(allIDs))
		if err != nil {
			return nil, err
		}
		if len(batch) == 0 {
			break
		}
		allIDs = append(allIDs, batch...)
	}

	return allIDs, nil
}

func fetchBatch(db *sql.DB, batchSize, offset int) ([]string, error) {
	rows, err := db.Query(
		"SELECT f.id FROM file f "+
			"WHERE f.id NOT IN (SELECT DISTINCT file_id FROM knowledge_file) "+
			"AND f.id NOT IN (SELECT DISTINCT cf.file_id FROM chat_file cf) "+
			"ORDER BY f.id "+
			"LIMIT $1 OFFSET $2",
		batchSize, offset,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return ids, nil
}

func deleteFile(apiBase, apiToken, id string, maxRetries int, retryDelay float64) (deleted bool, status int) {
	client := &http.Client{Timeout: defaultClientTimeout}

	for attempt := 0; attempt <= maxRetries; attempt++ {
		req, err := http.NewRequest("DELETE", apiBase+"/api/v1/files/"+id, nil)
		if err != nil {
			if attempt == maxRetries {
				return false, http.StatusInternalServerError
			}
			time.Sleep(backoff(attempt, retryDelay))
			continue
		}
		req.Header.Set("Authorization", "Bearer "+apiToken)
		resp, err := client.Do(req)
		if err != nil {
			if attempt == maxRetries {
				return false, 0
			}
			time.Sleep(backoff(attempt, retryDelay))
			continue
		}
		_, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
		switch resp.StatusCode {
		case http.StatusOK:
			return true, http.StatusOK
		case http.StatusNotFound:
			return true, http.StatusNotFound
		case http.StatusTooManyRequests:
			if attempt == maxRetries {
				return false, http.StatusTooManyRequests
			}
			wait := parseRetryAfter(resp.Header.Get("Retry-After"))
			if wait == 0 {
				wait = defaultRateLimitDelay
			}
			fmt.Printf("  %s rate-limited, retrying in %v (attempt %d/%d)\n", id, wait, attempt+1, maxRetries+1)
			time.Sleep(wait)
			continue
		default:
			if resp.StatusCode >= 500 && attempt < maxRetries {
				time.Sleep(backoff(attempt, retryDelay))
				continue
			}
			return false, resp.StatusCode
		}
	}
	return false, http.StatusTooManyRequests
}

func backoff(attempt int, retryDelay float64) time.Duration {
	base := time.Duration(float64(time.Second) * float64(retryDelay) * math.Pow(2, float64(attempt)))
	return base + time.Duration(rand.Float64()*float64(base)*0.5)
}

var retryAfterRegex = regexp.MustCompile(`^([0-9]+)$`)

func parseRetryAfter(header string) time.Duration {
	if header == "" {
		return 0
	}
	if matches := retryAfterRegex.FindStringSubmatch(strings.TrimSpace(header)); matches != nil {
		if seconds, err := strconv.ParseInt(matches[1], 10, 64); err == nil {
			return time.Duration(seconds) * time.Second
		}
	}
	return 0
}

func cleanup(fileIDs []string, apiBase, apiToken string, concurrency, maxRetries int, retryDelay float64, dryRun bool) (int, int) {
	if dryRun {
		fmt.Println("DRY RUN — nothing will be deleted.")
		return 0, len(fileIDs)
	}

	deleted := atomic.Int64{}
	failed := atomic.Int64{}

	var wg sync.WaitGroup
	sem := make(chan struct{}, 1)

	for i, id := range fileIDs {
		wg.Add(1)
		go func(idx int, fid string) {
			defer wg.Done()
			sem <- struct{}{}
			ok, status := deleteFile(apiBase, apiToken, fid, maxRetries, retryDelay)
			<-sem
			if ok {
				deleted.Add(1)
				if idx%50 == 0 {
					fmt.Printf("  Progress: %d/%d deleted, %d failed so far...\n",
						deleted.Load(), idx, failed.Load())
				}
			} else {
				failed.Add(1)
				fmt.Fprintf(os.Stderr, "  FAIL %s (status %d)\n", fid, status)
			}
		}(i, id)
	}

	wg.Wait()
	return int(deleted.Load()), int(failed.Load())
}
