package main

// Pacing for event sends. Synapse rate-limits messages per user (rc_message,
// by default about one every 5 s after a burst of 10). Your own WhatsApp
// messages are sent with your account (double puppeting), so a history
// import with many of your messages runs into that limit. mautrix bridgev2
// then gives up on the rest of that chat.
//
// The relay sits in front of every request the bridge makes, so it handles
// "too many requests" itself: event sends of one sender go one at a time, a
// 429 is retried after the time Synapse asks for, and the next sends of that
// sender are spaced out at the rate the server allows. The bridge only sees a
// slow response. If a send would wait longer than its HTTP timeout allows,
// the relay answers 429 with a Retry-After the bridge's client honours (up to
// 10 min, 4 retries), so it comes back later instead of failing.
// No server setting is changed.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// The bridge's HTTP client times out after 180 s; answer well before that.
var paceMaxHold = 160 * time.Second

var pacedPath = regexp.MustCompile(`^/_matrix/client/[^/]+/rooms/[^/]+/(send|redact|state)/`)

type paceLane struct {
	sem      chan struct{} // one send in flight per sender
	mu       sync.Mutex
	next     time.Time     // don't send before this
	interval time.Duration // learned spacing between sends, 0 = none
	waiting  atomic.Int64
}

type pacer struct {
	mu    sync.Mutex
	lanes map[string]*paceLane
	now   func() time.Time
	sleep func(time.Duration) // tests replace these

	hits    atomic.Int64 // 429s from the server
	retried atomic.Int64 // ... that the relay retried itself
	gaveUp  atomic.Int64 // sends handed back to the bridge with Retry-After
	waiting atomic.Int64
	lastHit atomic.Int64 // unix ms
}

func newPacer() *pacer {
	return &pacer{lanes: map[string]*paceLane{}, now: time.Now, sleep: time.Sleep}
}

func (p *pacer) lane(key string) *paceLane {
	p.mu.Lock()
	defer p.mu.Unlock()
	l := p.lanes[key]
	if l == nil {
		l = &paceLane{sem: make(chan struct{}, 1)}
		p.lanes[key] = l
	}
	return l
}

type PaceStatus struct {
	RateLimitHits int64      `json:"rate_limit_hits"`
	Retried       int64      `json:"rate_limit_retried"`
	HandedBack    int64      `json:"rate_limit_handed_back"`
	SendsWaiting  int64      `json:"sends_waiting"`
	LastHit       *time.Time `json:"last_rate_limit,omitempty"`
}

func (p *pacer) status() PaceStatus {
	if p == nil {
		return PaceStatus{}
	}
	s := PaceStatus{
		RateLimitHits: p.hits.Load(), Retried: p.retried.Load(),
		HandedBack: p.gaveUp.Load(), SendsWaiting: p.waiting.Load(),
	}
	if ms := p.lastHit.Load(); ms > 0 {
		t := time.UnixMilli(ms)
		s.LastHit = &t
	}
	return s
}

// recorder buffers a proxied response so a 429 can be retried.
type recorder struct {
	hdr  http.Header
	code int
	body bytes.Buffer
}

func (r *recorder) Header() http.Header         { return r.hdr }
func (r *recorder) Write(b []byte) (int, error) { return r.body.Write(b) }
func (r *recorder) WriteHeader(code int) {
	if r.code == 0 {
		r.code = code
	}
}

func (r *recorder) copyTo(w http.ResponseWriter) {
	for k, v := range r.hdr {
		w.Header()[k] = v
	}
	if r.code == 0 {
		r.code = http.StatusOK
	}
	w.WriteHeader(r.code)
	_, _ = w.Write(r.body.Bytes())
}

// retryAfter reads how long Synapse wants us to wait.
func retryAfter(r *recorder) time.Duration {
	var e struct {
		RetryAfterMS int64 `json:"retry_after_ms"`
	}
	if json.Unmarshal(r.body.Bytes(), &e) == nil && e.RetryAfterMS > 0 {
		return time.Duration(e.RetryAfterMS) * time.Millisecond
	}
	if s, err := strconv.Atoi(r.hdr.Get("Retry-After")); err == nil && s > 0 {
		return time.Duration(s) * time.Second
	}
	return 2 * time.Second
}

func handBack(w http.ResponseWriter, wait time.Duration) {
	secs := int(min(max(wait, 5*time.Second), 10*time.Minute).Seconds())
	w.Header().Set("Retry-After", strconv.Itoa(secs))
	writeErr(w, http.StatusTooManyRequests, "M_LIMIT_EXCEEDED",
		"Too Many Requests (relay is pacing sends, retry later)")
}

func (p *pacer) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodPut || !pacedPath.MatchString(req.URL.Path) || req.ContentLength > 1<<20 {
			next.ServeHTTP(w, req)
			return
		}
		body, err := io.ReadAll(io.LimitReader(req.Body, 1<<20+1))
		if err != nil {
			writeErr(w, http.StatusBadRequest, "M_UNKNOWN", "read body")
			return
		}
		if len(body) > 1<<20 { // too big to hold; pass it on unpaced
			req.Body = io.NopCloser(io.MultiReader(bytes.NewReader(body), req.Body))
			next.ServeHTTP(w, req)
			return
		}
		deadline := p.now().Add(paceMaxHold)
		// One lane per sender: the token, plus user_id for appservice ghosts.
		l := p.lane(req.Header.Get("Authorization") + "|" + req.URL.Query().Get("user_id"))

		l.waiting.Add(1)
		p.waiting.Add(1)
		defer p.waiting.Add(-1)
		timer := time.NewTimer(paceMaxHold)
		select {
		case l.sem <- struct{}{}:
			timer.Stop()
			l.waiting.Add(-1)
		case <-timer.C:
			l.waiting.Add(-1)
			p.gaveUp.Add(1)
			l.mu.Lock()
			wait := time.Duration(l.waiting.Load()+1) * max(l.interval, time.Second)
			l.mu.Unlock()
			handBack(w, wait)
			return
		case <-req.Context().Done():
			l.waiting.Add(-1)
			return
		}
		defer func() { <-l.sem }()

		for {
			l.mu.Lock()
			wait := l.next.Sub(p.now())
			l.mu.Unlock()
			if wait > 0 {
				if p.now().Add(wait).After(deadline) {
					p.gaveUp.Add(1)
					handBack(w, wait+time.Duration(l.waiting.Load())*l.interval)
					return
				}
				p.sleep(wait)
			}
			if req.Context().Err() != nil {
				return
			}
			out := req.Clone(req.Context())
			out.Body = io.NopCloser(bytes.NewReader(body))
			out.ContentLength = int64(len(body))
			rec := &recorder{hdr: http.Header{}}
			next.ServeHTTP(rec, out)

			l.mu.Lock()
			if rec.code != http.StatusTooManyRequests {
				// Ease off the spacing again while sends go through.
				l.interval = l.interval * 9 / 10
				if l.interval < 100*time.Millisecond {
					l.interval = 0
				}
				l.next = p.now().Add(l.interval)
				l.mu.Unlock()
				rec.copyTo(w)
				return
			}
			ra := retryAfter(rec)
			l.interval = min(max(ra, l.interval), time.Minute)
			l.next = p.now().Add(ra)
			l.mu.Unlock()
			p.hits.Add(1)
			p.lastHit.Store(p.now().UnixMilli())
			if p.now().Add(ra).After(deadline) {
				p.gaveUp.Add(1)
				handBack(w, ra+time.Duration(l.waiting.Load())*l.interval)
				return
			}
			p.retried.Add(1)
		}
	})
}
