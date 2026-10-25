package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPublicStatus(t *testing.T) {
	g, _, pub, _ := setup(t)
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	t.Cleanup(up.Close)
	down := httptest.NewServer(http.NotFoundHandler())
	down.Close()
	g.cfg.StatusChecks = []StatusCheck{{"whatsapp_bridge", up.URL + "/_matrix/mau/live"}, {"signal_bridge", down.URL}}
	g.cfg.LowSlotsWarning = 2

	if _, _, err := g.claim("@alice:example.com", "test"); err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest(http.MethodGet, pub.URL+"/status/v1", nil)
	req.Header.Set("Origin", "https://tjena.eu")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.Header.Get("Access-Control-Allow-Origin") != "*" {
		t.Error("no CORS header")
	}
	var st publicStatus
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{"synapse": true, "whatsapp_bridge": true, "signal_bridge": false, "bridge_proxy": true}
	if len(st.Services) != len(want) {
		t.Fatalf("services %+v", st.Services)
	}
	for _, s := range st.Services {
		if want[s.Name] != s.Online {
			t.Errorf("%s online=%v", s.Name, s.Online)
		}
	}
	if st.Slots.Free != 1 || st.Slots.Total != 2 || !st.Slots.Low {
		t.Errorf("slots %+v", st.Slots)
	}
	// Nothing about users or slot names leaks.
	raw, _ := json.Marshal(st)
	if strings.Contains(string(raw), "alice") || strings.Contains(string(raw), "wa01") {
		t.Errorf("status leaks: %s", raw)
	}
}
