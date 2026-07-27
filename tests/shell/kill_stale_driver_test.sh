#!/usr/bin/env bash
# kill_stale_driver_from_pidfile(): the comms watchdog's root SIGKILL of a wedged
# UPS driver, aimed by a PID read out of the nut-WRITABLE /var/run/nut.
#
# This is the highest-consequence branch in this repo that nothing else checks. A
# compromised nut process can write anything into that pidfile and root then acts
# on it: "-1" signals EVERY process in the container (PID 1 and all three daemons
# included), "0" and "000" address the caller's own process group, and a planted
# live PID of upsd/upsmon/PID 1 turns the watchdog into a confused deputy. The
# guards refuse each shape before signalling. tests/smoke.sh drives read_pidfile
# and pid_matches_binary separately, but never this function -- the one that
# decides whether to fire.
#
# TWO PROPERTIES EVERY CASE BELOW DEPENDS ON:
#   - pid_matches_binary is stubbed to SUCCEED in every refusal case. That is
#     load-bearing, not convenience: with identity failing, the LATER
#     not-verified-as-the-driver refusal stops the kill anyway, and each case
#     would pass with the guard it names deleted.
#   - `kill` is stubbed to a FILE, never a shell variable. The function's
#     side effect is the whole assertion, and a variable written inside a
#     command substitution is lost to the caller.
# The stub also answers `kill -0` from a controlled live-PID set rather than
# delegating to the real builtin, because a red-check that removes the numeric
# guard would otherwise run `kill -9 -1` for real.
#
# Lint directives for this whole file, each against a stated guarantee rather than
# an assumption:
#   SC2015 - the assertion form `[ cond ] && ok "..." || no "..."` cannot mis-fire,
#     because lib.sh's ok/no return 0 unconditionally by design (see their comment).
#   SC2034 - UPS_NAME/UPS_DRIVER are the INPUTS to lifecycle.sh code that is
#     extracted and sourced at RUNTIME, so shellcheck cannot see the reads.
# shellcheck disable=SC2015,SC2034
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The file under test. lib.sh defaults ENTRYPOINT to entrypoint.sh; this repo's
# lifecycle logic lives in a helper entrypoint.sh sources, so the default is
# redirected -- but a caller who SET ENTRYPOINT wins, which is how the documented
# red-check points this file at a mutated copy:
#   ENTRYPOINT=/tmp/mut-lifecycle.sh bash tests/shell/kill_stale_driver_test.sh
# Resolved before anything else reassigns ENTRYPOINT, so the override cannot be
# swallowed by the log_value load below.
SUBJECT="$REPO_ROOT/lifecycle.sh"
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] || SUBJECT="$ENTRYPOINT"

# log_value is defined in validate.sh (the standalone handlers carry their own
# copies); the entrypoint sources both files, so the real one is loaded here
# rather than stubbed -- the refusal LINES are part of what this file asserts.
# Always read from its own file: the override above aims at ONE target.
ENTRYPOINT="$REPO_ROOT/validate.sh"
load_function log_value

ENTRYPOINT="$SUBJECT"
load_function driver_binary
load_function kill_stale_driver_from_pidfile

UPS_NAME=ups
UPS_DRIVER=usbhid-ups
PIDFILE="$WORK/usbhid-ups-ups.pid"
SIGNALS="$WORK/signals.log"
WARN="$WORK/warn.log"
PROBES="$WORK/probes.log"
LIVE_PIDS=""
IDENTITY_OK=1

# Records every signal the function issues, so the assertion reads the real side
# effect. -0 (the liveness probe) is answered from LIVE_PIDS instead of the real
# builtin: a red-check that deletes the numeric guard makes the function reach
# `kill -0 -1` / `kill -9 -1`, which against the real builtin would signal every
# process in this container.
kill() {
  printf '%s\n' "$*" >>"$SIGNALS"
  if [ "$1" = "-0" ]; then
    # Count the liveness probes so the two -0 calls can be answered
    # independently: the shipped code probes ONCE before the identity check and
    # AGAIN immediately before the SIGKILL, to narrow the PID-reuse window. Only a
    # per-call answer can isolate the second probe from the first.
    printf 'x\n' >>"$PROBES"
    _kp=$(wc -l <"$PROBES")
    case "$LIVE_MODE" in
      first-only)
        [ "$_kp" -eq 1 ] && return 0
        return 1
        ;;
    esac
    case " $LIVE_PIDS " in
      *" $2 "*) return 0 ;;
    esac
    return 1
  fi
  return 0
}

# The privileged seam: the real read_pidfile drops to the nut user via BusyBox su
# and needs root plus that account, neither of which a unit test has. It is
# replaced by the same bounded read against the planted file, so the BAIT stays
# the real pidfile content the guards inspect.
read_pidfile() {
  head -c 64 "$1" 2>/dev/null || true
}

# /proc identity, stubbed BOTH ways so each guard can be isolated (see the header).
pid_matches_binary() {
  [ "$IDENTITY_OK" = 1 ]
}

# plant <pidfile-content> <live-pids> <identity-ok>
plant() {
  : >"$SIGNALS"
  : >"$WARN"
  : >"$PROBES"
  LIVE_MODE=list
  printf '%s' "$1" >"$PIDFILE"
  LIVE_PIDS="$2"
  IDENTITY_OK="$3"
  kill_stale_driver_from_pidfile "$PIDFILE" 2>"$WARN"
}

# plant_live_then_dead <pid> — the PID-reuse window: alive for the FIRST liveness
# probe, gone by the second. Identity passes, so only the re-check can refuse.
plant_live_then_dead() {
  : >"$SIGNALS"
  : >"$WARN"
  : >"$PROBES"
  LIVE_MODE=first-only
  printf '%s' "$1" >"$PIDFILE"
  LIVE_PIDS="$1"
  IDENTITY_OK=1
  kill_stale_driver_from_pidfile "$PIDFILE" 2>"$WARN"
}

probes() {
  wc -l <"$PROBES" | tr -d ' '
}

killed() {
  grep -q '^-9 ' "$SIGNALS"
}

refused_with() {
  grep -q "$1" "$WARN"
}

# --- 1. a non-numeric PID is never signalled ------------------------------------
#
# "-1" is the bait that matters: to kill(1) it is not a PID but "every process I
# may signal", so an unguarded root SIGKILL here kills PID 1 and every daemon on
# each watchdog recovery. It is also declared LIVE below, so the `kill -0`
# liveness probe cannot be what refuses it.
plant '-1' '-1 4242' 1
! killed && refused_with 'refusing non-numeric PID from pidfile' \
  && ok 'pidfile PID "-1" (= every process) is refused as non-numeric, no signal issued' \
  || no 'non-numeric PID "-1"' "signals=[$(tr '\n' ' ' <"$SIGNALS")]"

plant '1;rm -rf /' '4242' 1
! killed && refused_with 'refusing non-numeric PID from pidfile' \
  && ok 'a shell-metacharacter pidfile PID is refused as non-numeric' \
  || no 'non-numeric PID "1;rm -rf /"' "signals=[$(tr '\n' ' ' <"$SIGNALS")]"

# --- 2. an all-zero PID is refused independently of identity ---------------------
#
# The second, independent direction the numeric guard cannot cover: "0" IS
# numeric, so only the all-zero arm stands between the pidfile and a `kill -9 0`,
# which signals the caller's own process group -- PID 1 and its children.
plant '0' '0 4242' 1
! killed && refused_with 'refusing all-zero PID from pidfile' \
  && ok 'pidfile PID "0" (= the caller own process group) is refused by the all-zero arm' \
  || no 'all-zero PID "0"' "signals=[$(tr '\n' ' ' <"$SIGNALS")]"

plant '000' '000 4242' 1
! killed && refused_with 'refusing all-zero PID from pidfile' \
  && ok 'multi-digit all-zero pidfile PID "000" is refused too' \
  || no 'all-zero PID "000"' "signals=[$(tr '\n' ' ' <"$SIGNALS")]"

# --- 3. a LIVE PID that is not the driver is refused -----------------------------
#
# Bait must be live: a dead PID is filtered by the preceding `kill -0`, so the
# case would pass with the identity re-check gone.
plant '4242' '4242' 0
! killed && refused_with 'refusing to kill PID not verified as the UPS driver' \
  && ok 'a live PID whose /proc identity is not the UPS driver is refused' \
  || no 'unverified live PID' "signals=[$(tr '\n' ' ' <"$SIGNALS")]"

# --- 4. the two LIVENESS probes, isolated from each other -------------------------
# The shipped code probes `kill -0` twice: once as the gate before the identity
# check, and again immediately before the SIGKILL to narrow the PID-reuse window.
# Neither was pinned, so either could be deleted silently -- in a function that
# issues a root SIGKILL.

# The first probe: a DEAD numeric PID whose identity would pass. Nothing may be
# signalled and nothing refused-with-a-warning either; the PID simply is not there.
plant '4242' '' 1
! killed && [ ! -s "$WARN" ] \
  && ok 'a dead numeric PID is dropped by the first liveness probe, with no signal and no warning' \
  || no 'first liveness probe' "signals=[$(tr '\n' ' ' <"$SIGNALS")], warn: $(cat "$WARN")"

# The second probe: alive for the first probe, gone by the re-check. This is the
# PID-reuse window itself -- with the re-check deleted, the SIGKILL lands on
# whatever now holds that number.
plant_live_then_dead 4242
! killed && [ "$(probes)" -eq 2 ] \
  && ok 'a PID that dies between the two probes is not signalled (the re-check narrows PID reuse)' \
  || no 'second liveness probe' "probes=$(probes), signals=[$(tr '\n' ' ' <"$SIGNALS")]"

# --- 5. the positive control: the guards do not refuse everything -----------------
#
# Without this case every assertion above would also pass against a function that
# never signals at all, which is the failure mode a guard suite is most likely to
# hide.
plant '4242' '4242' 1
killed && ok 'a live PID verified as the UPS driver IS hard-killed (guards are not a blanket refusal)' \
  || no 'verified driver PID killed' "no -9 issued; signals=[$(tr '\n' ' ' <"$SIGNALS")]"

# --- 6. an empty pidfile issues no signal at all ---------------------------------
plant '' '4242' 1
[ ! -s "$SIGNALS" ] && ok 'an empty pidfile issues no signal at all, not even a liveness probe' \
  || no 'empty pidfile' "signals=[$(tr '\n' ' ' <"$SIGNALS")]"

# --- 6. the untrusted pidfile is dropped whatever the decision was ---------------
#
# The refusals leave the driver wedged, so the pidfile must not survive to aim the
# next recovery at the same planted PID.
plant '-1' '-1' 1
[ ! -e "$PIDFILE" ] && ok 'a refused (untrusted) pidfile is still removed' \
  || no 'refused pidfile removed' 'the planted pidfile survived the refusal'

plant '4242' '4242' 1
[ ! -e "$PIDFILE" ] && ok 'the pidfile is removed after a successful hard-kill' \
  || no 'killed pidfile removed' 'the pidfile survived the kill'

report
