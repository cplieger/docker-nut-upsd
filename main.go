// Command nut-exporter serves the UPS state upsd reports, and the state the
// image's own shell processes record, as Prometheus metrics on GET /metrics.
// entrypoint.sh starts it, validates its settings and supervises it.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"os/user"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/cplieger/go/httpserver"
	"github.com/cplieger/go/measure"
)

func main() {
	logger := newLogger(os.Stderr)
	if err := serve(logger); err != nil {
		logger.Error("metrics exporter stopped", "err", err.Error())
		os.Exit(1)
	}
}

func serve(logger *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	return run(ctx, os.Args[1:], logger)
}

// config is the exporter's command line, which entrypoint.sh builds from the
// image's validated settings.
type config struct {
	listen, upsd, ups, stateDir, user string
	hostPoweroff                      bool
}

func parseArgs(args []string) (config, error) {
	var c config
	fs := flag.NewFlagSet("nut-exporter", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&c.listen, "listen", "", "host:port to serve /metrics on")
	fs.StringVar(&c.upsd, "upsd", "", "host:port of upsd")
	fs.StringVar(&c.ups, "ups", "", "UPS name upsd serves")
	fs.StringVar(&c.stateDir, "state-dir", "", "directory the image's shell processes record their state in")
	fs.StringVar(&c.user, "user", "", "user to switch to after binding, when started as root")
	fs.BoolVar(&c.hostPoweroff, "host-poweroff", false, "SHUTDOWN_ON_BATTERY_CRITICAL")
	if err := fs.Parse(args); err != nil {
		return config{}, err
	}
	if fs.NArg() > 0 {
		return config{}, fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	for name, v := range map[string]string{"-listen": c.listen, "-upsd": c.upsd, "-ups": c.ups, "-state-dir": c.stateDir} {
		if v == "" {
			return config{}, fmt.Errorf("%s is required", name)
		}
	}
	return c, nil
}

// run binds the listener first, so a malformed address or a taken port fails
// before the ready file exists, and entrypoint.sh, which waits for that file,
// stops the boot.
func run(ctx context.Context, args []string, logger *slog.Logger) error {
	cfg, err := parseArgs(args)
	if err != nil {
		return err
	}
	var lc net.ListenConfig
	ln, err := lc.Listen(ctx, "tcp", cfg.listen)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", cfg.listen, err)
	}
	if err := writeReady(cfg.stateDir); err != nil {
		_ = ln.Close()
		return err
	}
	if err := dropPrivileges(cfg.user); err != nil {
		_ = ln.Close()
		return err
	}

	reg := measure.NewRegistry(metricPrefix)
	exp := newExporter(upsdClient{addr: cfg.upsd, ups: cfg.ups},
		wrapperState{dir: cfg.stateDir, proc: "/proc"}, cfg.hostPoweroff)
	if err := exp.register(reg); err != nil {
		_ = ln.Close()
		return fmt.Errorf("register metrics: %w", err)
	}
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", reg.Handler())
	srv := httpserver.New(mux)
	srv.ReadTimeout = 10 * time.Second
	srv.WriteTimeout = 10 * time.Second
	logger.Info("metrics exporter listening", "address", ln.Addr().String())
	return httpserver.Run(ctx, srv, ln)
}

func writeReady(dir string) error {
	if err := os.WriteFile(filepath.Join(dir, readyFile), nil, 0o600); err != nil {
		return fmt.Errorf("write ready file: %w", err)
	}
	return nil
}

// dropPrivileges switches a root process to name's user and group. The
// exporter needs root only to bind a port below 1024.
func dropPrivileges(name string) error {
	if name == "" || os.Geteuid() != 0 {
		return nil
	}
	u, err := user.Lookup(name)
	if err != nil {
		return fmt.Errorf("look up user %s: %w", name, err)
	}
	uid, uidErr := strconv.Atoi(u.Uid)
	gid, gidErr := strconv.Atoi(u.Gid)
	if err := errors.Join(uidErr, gidErr); err != nil {
		return fmt.Errorf("user %s: %w", name, err)
	}
	if err := syscall.Setgroups([]int{gid}); err != nil {
		return fmt.Errorf("set groups: %w", err)
	}
	if err := syscall.Setgid(gid); err != nil {
		return fmt.Errorf("set gid: %w", err)
	}
	if err := syscall.Setuid(uid); err != nil {
		return fmt.Errorf("set uid: %w", err)
	}
	return nil
}

// newLogger writes logfmt records that open with level=, as the image's shell
// does, so a rule anchored at ^level=error reads this program's errors too.
func newLogger(w io.Writer) *slog.Logger {
	return slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) > 0 {
				return a
			}
			switch a.Key {
			case slog.TimeKey:
				return slog.Attr{}
			case slog.LevelKey:
				if lvl, ok := a.Value.Any().(slog.Level); ok {
					return slog.String(slog.LevelKey, levelName(lvl))
				}
			}
			return a
		},
	}))
}

func levelName(l slog.Level) string {
	switch {
	case l >= slog.LevelError:
		return "error"
	case l >= slog.LevelWarn:
		return "warn"
	case l >= slog.LevelInfo:
		return "info"
	default:
		return "debug"
	}
}
