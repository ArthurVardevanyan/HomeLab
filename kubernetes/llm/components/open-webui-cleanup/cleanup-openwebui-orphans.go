package main

import (
	"database/sql"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	_ "github.com/lib/pq"
)

//nolint:lll // Database connection string can be long
const defaultDBURI = "postgres://postgres:postgres@open-webui-rw.llm.svc.cluster.local:5432/openwebui?sslmode=require"
const defaultAPIBase = "http://open-webui.llm.svc.cluster.local:8080"

func main() {
	dryRun := flag.Bool("dry-run", false, "show what would be deleted without deleting")
	dbURI := flag.String("db-uri", os.Getenv("DATABASE_URL"), "PostgreSQL connection URI")
	apiToken := flag.String("api-token", os.Getenv("OWUI_API_TOKEN"), "Open WebUI API bearer token")
	concurrency := flag.Int("concurrency", 5, "number of concurrent API deletes")
	apiBase := flag.String("api-base", os.Getenv("OWUI_API_BASE"), "Open WebUI API base URL")
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

	fileIDs, err := getOrphanedFileIDs(db)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Query error: %v\n", err)
		os.Exit(1)
	}

	if len(fileIDs) == 0 {
		fmt.Println("No orphaned files found. Nothing to do.")
		return
	}

	fmt.Printf("Found %d orphaned files.\n\n", len(fileIDs))

	deleted, failed := cleanup(fileIDs, *apiBase, *apiToken, *concurrency, *dryRun)
	fmt.Printf("Deleted: %d\nFailed: %d\n", deleted, failed)

	if failed > 0 {
		os.Exit(1)
	}
}

func getOrphanedFileIDs(db *sql.DB) ([]string, error) {
	rows, err := db.Query(
		"SELECT f.id FROM file f " +
			"WHERE f.id NOT IN (SELECT DISTINCT file_id FROM knowledge_file) " +
			"AND f.id NOT IN (SELECT DISTINCT cf.file_id FROM chat_file cf)",
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
	return ids, rows.Err()
}

func cleanup(fileIDs []string, apiBase, apiToken string, concurrency int, dryRun bool) (int, int) {
	if dryRun {
		fmt.Println("DRY RUN — nothing will be deleted.")
		return 0, len(fileIDs)
	}

	client := &http.Client{Timeout: 30 * time.Second}
	deleted := atomic.Int64{}
	failed := atomic.Int64{}

	var wg sync.WaitGroup
	sem := make(chan struct{}, concurrency)

	for _, id := range fileIDs {
		wg.Add(1)
		sem <- struct{}{}
		go func(fid string) {
			defer wg.Done()
			defer func() { <-sem }()

			url := apiBase + "/api/v1/files/" + fid
			req, err := http.NewRequest("DELETE", url, nil)
			if err != nil {
				failed.Add(1)
				fmt.Fprintf(os.Stderr, "  FAIL %s: req: %v\n", fid, err)
				return
			}
			req.Header.Set("Authorization", "Bearer "+apiToken)

			resp, err := client.Do(req)
			if err != nil {
				failed.Add(1)
				fmt.Fprintf(os.Stderr, "  FAIL %s: %v\n", fid, err)
				return
			}
			defer resp.Body.Close()

			body, _ := io.ReadAll(resp.Body)

			switch resp.StatusCode {
			case http.StatusOK:
				deleted.Add(1)
				if deleted.Load()%500 == 0 {
					fmt.Printf("  Processed: %d deleted, %d failed so far...\n",
						deleted.Load(), failed.Load())
				}
			case http.StatusNotFound:
				deleted.Add(1)
			default:
				failed.Add(1)
				msg := strings.TrimSpace(string(body))
				if len(msg) > 200 {
					msg = msg[:200]
				}
				fmt.Fprintf(os.Stderr, "  FAIL %s: %s %s\n", fid, resp.Status, msg)
			}
		}(id)
	}

	wg.Wait()
	return int(deleted.Load()), int(failed.Load())
}
