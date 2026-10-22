package main

import (
	"net/http"
	"net/http/httputil"
	"net/url"
)

// clientProxy forwards the bridge's normal Matrix client-API and media calls
// to Synapse. If the request carries a bridge token, it is swapped for the
// slot's real as_token, which never leaves the gateway. That makes revoking a
// bridge instant and restart-free: drop the bridge token and every request it
// makes is rejected by Synapse.
//
// The gateway does NOT check which user the bridge acts as (user_id=, device
// masquerading). Synapse already restricts each slot's as_token to that
// slot's namespace, so a bug here cannot reach another slot's users.
//
// Requests with any other token (e.g. the owner's double-puppet session) are
// passed through unchanged, exactly as if they had gone to Synapse directly.
func (g *Gateway) clientProxy() http.Handler {
	target, err := url.Parse(g.cfg.SynapseURL)
	if err != nil {
		panic(err)
	}
	return &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			// Keep the incoming forwarded-for chain (Cloudflare), then append.
			pr.Out.Header["X-Forwarded-For"] = pr.In.Header["X-Forwarded-For"]
			pr.SetXForwarded()
			g.swapToken(pr.Out)
		},
		FlushInterval: -1, // stream (long-poll /sync, media)
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			g.log.Warn("client proxy error", "path", r.URL.Path, "err", err)
			writeError(w, http.StatusBadGateway, "M_UNKNOWN", "Homeserver unreachable")
		},
	}
}

func (g *Gateway) swapToken(r *http.Request) {
	tok := bearer(r)
	if tok == "" {
		return
	}
	g.mu.RLock()
	name, ok := g.byBridgeAS[tok]
	g.mu.RUnlock()
	if !ok {
		return
	}
	s, ok := g.slot(name)
	if !ok || s.State != SlotAssigned || s.BridgeASToken != tok {
		return
	}
	r.Header.Set("Authorization", "Bearer "+s.ASToken)
	if q := r.URL.Query(); q.Has("access_token") {
		q.Del("access_token")
		r.URL.RawQuery = q.Encode()
	}
}
