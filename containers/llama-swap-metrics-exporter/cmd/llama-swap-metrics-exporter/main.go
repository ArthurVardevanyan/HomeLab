package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/common/expfmt"
)

const (
	defaultLlamaSwapAddr  = "http://localhost:8080"
	defaultListenAddr     = ":9100"
	defaultScrapeInterval = 10 * time.Second
	// llama-server's /metrics can be blocked for many seconds by its own
	// HTTP thread pool (--threads-http 2) during heavy prefill/decode on
	// long-context requests (observed: 100K+ token prompts). 15s gives
	// genuinely busy-but-alive instances a fair chance to respond before
	// we fall back to the cached value, without hanging the scrape cycle
	// indefinitely.
	defaultScrapeTimeout = 15 * time.Second
	// How long a model's last-successfully-scraped metrics may be served
	// as a stale fallback after a failed scrape, before being dropped
	// entirely. Bounds staleness for an instance that's genuinely stuck,
	// while smoothing over the transient HTTP-thread-pool-contention gaps
	// described above.
	maxStaleness = 5 * time.Minute
)

var (
	scrapeDuration = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "exporter_scrape_duration_seconds",
		Help: "Time each scrape cycle took",
	})

	scrapeErrors = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "exporter_scrape_errors_total",
		Help: "Number of failed upstream scrapes",
	})

	modelsDiscovered = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "exporter_models_discovered",
		Help: "Number of models currently discovered",
	})

	exporterReady = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "exporter_ready",
		Help: "Whether the exporter is ready and collecting metrics",
	})

	llamaSwapAddr = defaultLlamaSwapAddr
	listenAddr    = defaultListenAddr
)

func init() {
	prometheus.MustRegister(scrapeDuration)
	prometheus.MustRegister(scrapeErrors)
	prometheus.MustRegister(modelsDiscovered)
	prometheus.MustRegister(exporterReady)
}

// runningResponse mirrors llama-swap's GET /running response:
//
//	{"running":[{"model":"35b-gpu0","state":"ready",
//	  "proxy":"http://localhost:5802", ...}]}
type runningResponse struct {
	Running []runningModel `json:"running"`
}

type runningModel struct {
	Model string `json:"model"`
	State string `json:"state"`
	Proxy string `json:"proxy"`
}

// port extracts the numeric port from the "proxy" URL (e.g.
// "http://localhost:5802" -> 5802). Returns 0 if it can't be parsed.
func (m runningModel) port() int {
	u, err := url.Parse(m.Proxy)
	if err != nil {
		return 0
	}
	p, err := strconv.Atoi(u.Port())
	if err != nil {
		return 0
	}
	return p
}

// cachedMetrics holds the last successfully-scraped metrics for a model,
// used as a fallback when a scrape fails (e.g. the llama-server instance is
// temporarily unresponsive under heavy load).
type cachedMetrics struct {
	metrics   map[string]string
	updatedAt time.Time
}

type scraper struct {
	client *http.Client
	mux    sync.Mutex

	active map[string]int // modelID -> port, from the most recent discovery

	// metrics is what's currently served on /metrics: either freshly
	// scraped this cycle, or a fallback from lastGood within maxStaleness.
	metrics map[string]map[string]string

	lastGood  map[string]cachedMetrics // modelID -> last successful scrape
	failCount map[string]int           // modelID -> consecutive scrape failures
}

func newScraper() *scraper {
	return &scraper{
		client: &http.Client{
			Timeout: defaultScrapeTimeout,
		},
		active:    make(map[string]int),
		metrics:   make(map[string]map[string]string),
		lastGood:  make(map[string]cachedMetrics),
		failCount: make(map[string]int),
	}
}

func (s *scraper) discover(ctx context.Context) error {
	reqURL := fmt.Sprintf("%s/running", llamaSwapAddr)
	req, err := http.NewRequestWithContext(ctx, "GET", reqURL, nil)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("fetch /running: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("/running returned status %d", resp.StatusCode)
	}

	var running runningResponse
	if err := json.NewDecoder(resp.Body).Decode(&running); err != nil {
		return fmt.Errorf("decode /running: %w", err)
	}

	active := make(map[string]int)
	for _, m := range running.Running {
		// Only scrape models that are fully up; a model mid-load/mid-swap
		// won't have its llama-server metrics endpoint reliably reachable.
		if m.State != "ready" {
			continue
		}
		if p := m.port(); p > 0 {
			active[m.Model] = p
		}
	}

	s.mux.Lock()
	s.active = active
	s.mux.Unlock()

	return nil
}

func (s *scraper) scrapeModel(ctx context.Context, modelID string, port int) (map[string]string, error) {
	reqURL := fmt.Sprintf("http://localhost:%d/metrics?model=%s", port, modelID)
	req, err := http.NewRequestWithContext(ctx, "GET", reqURL, nil)
	if err != nil {
		return nil, fmt.Errorf("create scrape request for %s: %w", modelID, err)
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("scrape %s: %w", modelID, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("scrape %s returned status %d", modelID, resp.StatusCode)
	}

	metrics := make(map[string]string)
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read %s metrics: %w", modelID, err)
	}

	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, " ", 2)
		if len(parts) == 2 {
			metrics[parts[0]] = parts[1]
		}
	}

	return metrics, nil
}

// shouldLog throttles repeated failure logging: log the first failure, then
// only every 6th (roughly once a minute at the default 10s scrape interval)
// while the instance stays down, instead of spamming every cycle.
func shouldLog(consecutiveFailures int) bool {
	return consecutiveFailures == 1 || consecutiveFailures%6 == 0
}

type scrapeResult struct {
	id      string
	metrics map[string]string
	err     error
}

func (s *scraper) scrape(ctx context.Context) {
	start := time.Now()
	defer func() {
		scrapeDuration.Set(float64(time.Since(start).Microseconds()) / 1e6)
	}()

	if err := s.discover(ctx); err != nil {
		log.Printf("discovery error: %v", err)
		return
	}

	s.mux.Lock()
	active := make(map[string]int, len(s.active))
	for id, port := range s.active {
		active[id] = port
	}
	s.mux.Unlock()

	results := make(chan scrapeResult, len(active))
	var wg sync.WaitGroup
	for modelID, port := range active {
		wg.Add(1)
		go func(id string, p int) {
			defer wg.Done()
			m, err := s.scrapeModel(ctx, id, p)
			results <- scrapeResult{id: id, metrics: m, err: err}
		}(modelID, port)
	}
	wg.Wait()
	close(results)

	s.mux.Lock()
	defer s.mux.Unlock()

	newMetrics := make(map[string]map[string]string, len(active))
	now := time.Now()
	errCount := 0

	for r := range results {
		if r.err != nil {
			errCount++
			s.failCount[r.id]++
			if cached, ok := s.lastGood[r.id]; ok && now.Sub(cached.updatedAt) <= maxStaleness {
				newMetrics[r.id] = cached.metrics
				if shouldLog(s.failCount[r.id]) {
					log.Printf("scrape error for %s (serving cached metrics from %s ago, %d consecutive failures): %v",
						r.id, now.Sub(cached.updatedAt).Round(time.Second), s.failCount[r.id], r.err)
				}
			} else if shouldLog(s.failCount[r.id]) {
				log.Printf("scrape error for %s (no fresh cache available, %d consecutive failures): %v",
					r.id, s.failCount[r.id], r.err)
			}
			continue
		}

		if s.failCount[r.id] > 0 {
			log.Printf("scrape recovered for %s after %d consecutive failures", r.id, s.failCount[r.id])
		}
		s.failCount[r.id] = 0
		s.lastGood[r.id] = cachedMetrics{metrics: r.metrics, updatedAt: now}
		newMetrics[r.id] = r.metrics
	}

	// Prune cache/failure state for models that are no longer active
	// (unloaded/evicted), so served metrics don't accumulate stale entries
	// forever.
	for id := range s.lastGood {
		if _, ok := active[id]; !ok {
			delete(s.lastGood, id)
			delete(s.failCount, id)
		}
	}

	if errCount > 0 {
		scrapeErrors.Add(float64(errCount))
	}

	s.metrics = newMetrics
	modelsDiscovered.Set(float64(len(active)))
	exporterReady.Set(1)
	atomic.StoreInt32(&ready, 1)
}

// withModelLabel builds a valid Prometheus exposition-format metric
// identifier, merging a model="..." label into any label block the scraped
// metric name may already carry. Most llamacpp:* metrics are bare (e.g.
// "llamacpp:prompt_tokens_total"), but llamacpp:spec_decode_num_accepted_tokens_per_pos_total
// ships its own inline label (e.g. `...{position="6"}`) — naively appending
// a second "{model=\"...\"}" block after it produces invalid syntax
// (two adjacent brace groups), which aborts the *entire* scrape on the
// Prometheus side, not just that one metric. This merges into a single
// brace group regardless of whether the source metric already had labels.
func withModelLabel(name, modelID string) string {
	if idx := strings.Index(name, "{"); idx != -1 {
		base := name[:idx]
		body := strings.TrimSuffix(name[idx+1:], "}")
		return fmt.Sprintf("%s{model=%q,%s}", base, modelID, body)
	}
	return fmt.Sprintf("%s{model=%q}", name, modelID)
}

// metricsHandler renders a single combined text-exposition response: the
// built-in exporter_* metrics (via prometheus.DefaultGatherer) plus the
// manually-scraped llamacpp:* lines. Deliberately does NOT delegate to
// promhttp.Handler(): that handler auto-negotiates gzip based on the
// request's Accept-Encoding (which Prometheus always sends), and writing
// more plain-text data to the same ResponseWriter afterward corrupts the
// gzip stream ("gzip: invalid header" on the scraping side). Building the
// full body in memory first and writing it uncompressed in one shot avoids
// that entirely — gzip is an optional transport optimization, not required
// by the exposition format.
func metricsHandler(s *scraper) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s.mux.Lock()
		defer s.mux.Unlock()

		var buf bytes.Buffer

		mfs, err := prometheus.DefaultGatherer.Gather()
		if err != nil {
			http.Error(w, fmt.Sprintf("failed to gather metrics: %v", err), http.StatusInternalServerError)
			return
		}
		for _, mf := range mfs {
			if _, err := expfmt.MetricFamilyToText(&buf, mf); err != nil {
				log.Printf("failed to encode metric family %s: %v", mf.GetName(), err)
			}
		}

		// Append scraped llama.cpp metrics with model labels
		for modelID, metrics := range s.metrics {
			for name, value := range metrics {
				fmt.Fprintf(&buf, "%s %s\n", withModelLabel(name, modelID), value)
			}
		}

		// Per-model last-successful-scrape timestamp, for alerting on
		// staleness (e.g. a model stuck unresponsive for longer than
		// scrape_interval * a few).
		for modelID, cached := range s.lastGood {
			fmt.Fprintf(&buf, "exporter_model_last_success_timestamp_seconds{model=%q} %d\n",
				modelID, cached.updatedAt.Unix())
		}

		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		w.Write(buf.Bytes())
	}
}

var ready int32

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if atomic.LoadInt32(&ready) == 1 {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ready"))
	} else {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte("starting"))
	}
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	s := newScraper()

	addr := os.Getenv("LLAMA_SWAP_ADDR")
	if addr != "" {
		llamaSwapAddr = addr
	}

	listen := os.Getenv("LISTEN_ADDR")
	if listen != "" {
		listenAddr = listen
	}

	go func() {
		ticker := time.NewTicker(defaultScrapeInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				s.scrape(context.Background())
			}
		}
	}()

	http.HandleFunc("/metrics", metricsHandler(s))
	http.HandleFunc("/health", healthHandler)
	http.HandleFunc("/ready", healthHandler)

	log.Printf("starting metrics exporter on %s (llama-swap at %s)", listenAddr, llamaSwapAddr)
	if err := http.ListenAndServe(listenAddr, nil); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
