package main

// Public service status for the tjena website: GET /status/v1 on the public
// listener. No auth, CORS open, cached so visitors can't load the backends.
// It shows only up/down per service and slot counts, never users or slots.

import (
	"context"
	"net/http"
	"sync"
	"time"
)

const (
	statusCacheFor = 30 * time.Second
	statusTimeout  = 3 * time.Second
)

type serviceStatus struct {
	Name      string `json:"name"`
	Online    bool   `json:"online"`
	LatencyMS int64  `json:"latency_ms,omitempty"`
}

type publicStatus struct {
	Updated  time.Time       `json:"updated"`
	Services []serviceStatus `json:"services"`
	Slots    struct {
		Free  int  `json:"free"`
		Total int  `json:"total"`
		Low   bool `json:"low"`
	} `json:"personal_bridge_slots"`
}

type statusCache struct {
	mu   sync.Mutex
	at   time.Time
	last publicStatus
}

// freeSlots counts slots a new user could get now, and all usable slots.
func (g *Gateway) freeSlots() (free, total int) {
	g.store.View(func(st *stateFile) {
		for _, s := range st.Slots {
			if s.State == SlotBurned || !s.Active {
				continue
			}
			total++
			if s.State == SlotFree {
				free++
			}
		}
	})
	return
}

// probe reports whether url answers 2xx within statusTimeout.
func (g *Gateway) probe(ctx context.Context, url string) (bool, int64) {
	ctx, cancel := context.WithTimeout(ctx, statusTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, 0
	}
	start := time.Now()
	resp, err := g.client.Do(req)
	if err != nil {
		return false, 0
	}
	_ = resp.Body.Close()
	return resp.StatusCode >= 200 && resp.StatusCode < 300, time.Since(start).Milliseconds()
}

func (g *Gateway) buildStatus(ctx context.Context) publicStatus {
	checks := append([]StatusCheck{{Name: "synapse", URL: g.cfg.SynapseURL + "/health"}}, g.cfg.StatusChecks...)
	out := publicStatus{Updated: time.Now().UTC(), Services: make([]serviceStatus, len(checks)+1)}
	var wg sync.WaitGroup
	for i, c := range checks {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ok, ms := g.probe(ctx, c.URL)
			out.Services[i] = serviceStatus{Name: c.Name, Online: ok, LatencyMS: ms}
		}()
	}
	wg.Wait()
	// Answering at all means the proxy is up.
	out.Services[len(checks)] = serviceStatus{Name: "bridge_proxy", Online: true}
	out.Slots.Free, out.Slots.Total = g.freeSlots()
	out.Slots.Low = out.Slots.Free < g.cfg.LowSlotsWarning
	return out
}

// GET /status/v1
func (g *Gateway) handlePublicStatus(w http.ResponseWriter, r *http.Request) {
	c := &g.status
	c.mu.Lock()
	if time.Since(c.at) > statusCacheFor {
		c.last = g.buildStatus(r.Context())
		c.at = time.Now()
	}
	st := c.last
	c.mu.Unlock()
	w.Header().Set("Cache-Control", "public, max-age=30")
	writeJSON(w, http.StatusOK, st)
}

// warnLowSlots logs when the pool is nearly empty (checked with activation).
func (g *Gateway) warnLowSlots() {
	free, total := g.freeSlots()
	if total > 0 && free < g.cfg.LowSlotsWarning {
		g.log.Warn("few free bridge slots: run slots-add and restart Synapse", "free", free, "total", total)
	}
}
