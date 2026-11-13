package main

import (
	"context"
	"errors"
	"strconv"
	"strings"

	"github.com/cplieger/go/measure"
)

// metricPrefix prefixes every family name; alerts/promql.yaml reads the prefixed names.
const metricPrefix = "nut_upsd"

// version is the image release and nutVersion the NUT release it compiles,
// both stamped by the Dockerfile's go build line.
var (
	version    = "dev"
	nutVersion = "unknown"
)

// statusFlags are the ups.status tokens a NUT v2.8.5 driver sets
// (docs/new-drivers.txt "Status data"), ALARM, which NUT adds itself, and ECO,
// which upsmon reads (clients/upsmon.c). Each is served on every fresh read, 0
// or 1, so a rule on a flag has a series to read; any other token sets OTHER,
// as upsmon's own OTHER event does.
var statusFlags = []string{
	"OL", "OB", "LB", "HB", "RB", "CHRG", "DISCHRG", "BYPASS", "CAL", "OFF",
	"OVER", "TRIM", "BOOST", "FSD", "ALARM", "ECO", "OTHER",
}

// upsVariable maps one numeric NUT variable to its series, scaled to a base
// unit: NUT reports percentages, which the series serve as ratios.
type upsVariable struct {
	nut, metric, help string
	scale             float64
}

var upsVariables = []upsVariable{
	{"battery.charge", "battery_charge_ratio", "Battery charge, 0 to 1.", 0.01},
	{"battery.charge.low", "battery_charge_low_ratio", "Battery charge at which the UPS reports low battery, 0 to 1.", 0.01},
	{"battery.runtime", "battery_runtime_seconds", "Battery runtime left at the current load.", 1},
	{"battery.runtime.low", "battery_runtime_low_seconds", "Battery runtime at which the UPS reports low battery.", 1},
	{"battery.voltage", "battery_voltage_volts", "Battery voltage.", 1},
	{"battery.temperature", "battery_temperature_celsius", "Battery temperature.", 1},
	{"input.voltage", "input_voltage_volts", "Input (mains) voltage.", 1},
	{"input.frequency", "input_frequency_hertz", "Input (mains) frequency.", 1},
	{"output.voltage", "output_voltage_volts", "Output voltage.", 1},
	{"output.frequency", "output_frequency_hertz", "Output frequency.", 1},
	{"ups.load", "ups_load_ratio", "Load on the UPS as a share of its rating, 0 to 1.", 0.01},
	{"ups.realpower", "ups_realpower_watts", "Real power the load draws.", 1},
	{"ups.realpower.nominal", "ups_realpower_nominal_watts", "Rated real power of the UPS.", 1},
	{"ups.power", "ups_power_voltamperes", "Apparent power the load draws.", 1},
	{"ups.power.nominal", "ups_power_nominal_voltamperes", "Rated apparent power of the UPS.", 1},
	{"ups.temperature", "ups_temperature_celsius", "UPS temperature.", 1},
}

// exporter reads upsd and the wrapper's state at scrape time.
type exporter struct {
	upsdUp, dataFresh, status            *measure.Desc
	driverRestarts, parentAlive          *measure.Desc
	poweroffEnabled, poweroffOK, probeAt *measure.Desc
	upsd                                 upsdClient
	state                                wrapperState
	vars                                 []*measure.Desc
	hostPoweroff                         bool
}

func newExporter(upsd upsdClient, state wrapperState, hostPoweroff bool) *exporter {
	e := &exporter{
		upsd:         upsd,
		state:        state,
		hostPoweroff: hostPoweroff,
		upsdUp:       measure.NewGaugeDesc("upsd_up", "1 when upsd answered the NUT protocol on the last scrape.", nil),
		dataFresh:    measure.NewGaugeDesc("ups_data_fresh", "1 when upsd served fresh data for the UPS, 0 when the data is stale, the driver is gone or upsd did not answer.", nil),
		status:       measure.NewGaugeDesc("ups_status", "1 when ups.status carries the flag, 0 when it does not. Served only while the data is fresh.", []string{"flag"}),
		driverRestarts: measure.NewCounterDesc("driver_restarts_total",
			"UPS driver restarts the comms watchdog issued since the container started.", nil),
		parentAlive: measure.NewGaugeDesc("upsmon_parent_alive",
			"1 while upsmon's privileged parent, the process that runs the shutdown command, is running. Served only once the container has started upsmon.", nil),
		poweroffEnabled: measure.NewGaugeDesc("host_poweroff_enabled",
			"1 when SHUTDOWN_ON_BATTERY_CRITICAL lets a forced shutdown power off the host.", nil),
		poweroffOK: measure.NewGaugeDesc("poweroff_path_ok",
			"1 when the last D-Bus probe found the host poweroff path usable, 0 when it did not. Served only once a probe has run.", nil),
		probeAt: measure.NewGaugeDesc("poweroff_path_probe_timestamp_seconds",
			"Unix time of the last D-Bus poweroff path probe.", nil),
	}
	for _, v := range upsVariables {
		e.vars = append(e.vars, measure.NewGaugeDesc(v.metric, v.help, nil))
	}
	return e
}

// register adds the exporter's families to a registry built with metricPrefix.
func (e *exporter) register(reg *measure.Registry) error {
	descs := append([]*measure.Desc{
		e.upsdUp, e.dataFresh, e.status, e.driverRestarts, e.parentAlive,
		e.poweroffEnabled, e.poweroffOK, e.probeAt,
	}, e.vars...)
	return reg.Register(measure.NewCollector(e.collect, descs...))
}

// registerBuildInfo serves build_info at 1, labelled with the releases this
// image runs, for a query to join on.
func registerBuildInfo(reg *measure.Registry) error {
	info := measure.NewLabeledGauge("build_info",
		"Always 1; the labels are the image release and the NUT release it runs.", []string{"version", "nut_version"})
	if err := reg.Register(info); err != nil {
		return err
	}
	info.Set(1, version, nutVersion)
	return nil
}

func (e *exporter) collect(ctx context.Context, em *measure.Emitter) {
	vars, err := e.upsd.listVars(ctx)
	em.Emit(e.upsdUp, boolValue(err == nil || errors.Is(err, errUPSData)))
	em.Emit(e.dataFresh, boolValue(err == nil))
	if err == nil {
		e.emitStatus(em, vars["ups.status"])
		for i, v := range upsVariables {
			if f, err := strconv.ParseFloat(vars[v.nut], 64); err == nil {
				em.Emit(e.vars[i], f*v.scale)
			}
		}
	}

	em.Emit(e.driverRestarts, float64(e.state.driverRestarts()))
	if alive, recorded := e.state.upsmonParent(); recorded {
		em.Emit(e.parentAlive, boolValue(alive))
	}
	em.Emit(e.poweroffEnabled, boolValue(e.hostPoweroff))
	if ok, at, found := e.state.poweroffPath(); found {
		em.Emit(e.poweroffOK, boolValue(ok))
		em.Emit(e.probeAt, float64(at.Unix()))
	}
}

func (e *exporter) emitStatus(em *measure.Emitter, status string) {
	set := make(map[string]bool, len(statusFlags))
	for token := range strings.FieldsSeq(status) {
		if isStatusFlag(token) {
			set[token] = true
		} else {
			set["OTHER"] = true
		}
	}
	for _, flag := range statusFlags {
		em.Emit(e.status, boolValue(set[flag]), flag)
	}
}

func isStatusFlag(token string) bool {
	for _, flag := range statusFlags {
		if flag == token && flag != "OTHER" {
			return true
		}
	}
	return false
}

func boolValue(b bool) float64 {
	if b {
		return 1
	}
	return 0
}
