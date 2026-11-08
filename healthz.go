package main

import (
	"context"
	"net/http"

	"github.com/cplieger/go/health"
)

const upsStatusStaleReason = "upsd has no fresh status for the UPS: the data is stale, the driver is not connected, or upsd did not answer."

// upsStatusFresh is the question the image's HEALTHCHECK asks upsd through
// comms_fresh in lifecycle.sh, `upsc <ups> ups.status` under a 3-second bound,
// so /healthz and Docker health give one verdict. Change both together.
type upsStatusFresh struct {
	upsd upsdClient
}

// Healthy reports whether upsd answered with the UPS's ups.status. upsd runs
// the same ups_available check before LIST VAR as before the GET VAR upsc
// sends (NUT v2.8.5 server/netlist.c, server/netget.c).
func (s upsStatusFresh) Healthy() bool {
	vars, err := s.upsd.listVars(context.Background())
	_, ok := vars["ups.status"]
	return err == nil && ok
}

func healthzHandler(upsd upsdClient) http.Handler {
	return health.CheckHandler(health.Check{Signal: upsStatusFresh{upsd: upsd}, Reason: upsStatusStaleReason})
}
