#!/bin/bash
# Records what the processor and macOS report about the CPU's limits through a series of loads,
# so that the way Power Gauge reads them can be checked against real samples:
#   sudo scripts/throttle-survey.sh
# It needs root, for powermetrics, and takes about 6 minutes. Quit other heavy apps first and
# stop monitoring in Power Gauge. Leave the Mac alone while it runs; plugged in or not, as you
# normally use it (the survey notes which).
#   scripts/throttle-survey.sh --dry-run   tries the scenarios, the loads and the log for 2 s
#                                          each, without powermetrics or root
#
# The scenarios, in order: idle; one core busy; half the CPUs busy; every CPU busy for 90 s
# (long enough to pass the short-term power limit); a rest; the integrated GPU busy; every CPU
# and the integrated GPU busy; the other GPU busy; and a rest to cool down. The CPUs are kept
# busy with `yes`, the GPUs with Power Gauge's own --gpu-load.
#
# It writes build/throttle-survey/<date and time>/:
#   powermetrics.plist   every sample, one a second, with the arguments in arguments.txt
#   system.tsv           each second: the time, the scenario, macOS's speed and scheduler
#                        limits and available CPUs (pmset -g therm), Low Power Mode, and the
#                        kernel's frequency ceilings and thermal levels (sysctl machdep.xcpm)
#   scenarios.tsv        when each scenario started and ended
#   about.txt            the Mac, macOS, the power source and the app's diagnostic report
set -euo pipefail
# Says where it stopped, should anything fail, rather than stopping without a word.
trap 'echo "throttle-survey.sh stopped at line $LINENO: $BASH_COMMAND" >&2' ERR
cd "$(dirname "$0")/.."

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; fi
if [ $DRY -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
	echo "Run it with sudo: sudo $0" >&2
	exit 1
fi
APP="$(pwd)/build/Power Gauge.app/Contents/MacOS/PowerGauge"
if [ ! -x "$APP" ]; then
	echo "Build the app first: scripts/build.sh" >&2
	exit 1
fi
if [ $DRY -eq 0 ] && pgrep -x powermetrics > /dev/null; then
	echo "powermetrics is already running, perhaps for Power Gauge. Stop monitoring there, then run this again." >&2
	exit 1
fi
OWNER="${SUDO_USER:-$(id -un)}"
OUT="build/throttle-survey/$(date +%Y-%m-%d-%H%M%S)"
if [ $DRY -eq 1 ]; then OUT="$OUT-dry-run"; fi
mkdir -p "$OUT"
CPUS="$(sysctl -n hw.logicalcpu)"

# Runs a command as the person who ran sudo, for the GPU loads, which need their session.
as_owner() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$OWNER" "$@"; else "$@"; fi; }

LOADS=()
LOGGER="" PM=""
stop_loads() {
	for P in ${LOADS[@]+"${LOADS[@]}"}; do kill "$P" 2> /dev/null || true; done
	LOADS=()
}
finish() {
	stop_loads
	[ -n "$LOGGER" ] && kill "$LOGGER" 2> /dev/null || true
	[ -n "$PM" ] && kill "$PM" 2> /dev/null || true
	wait 2> /dev/null || true
	chown -R "$OWNER" build/throttle-survey 2> /dev/null || true
}
trap finish EXIT
trap 'echo; echo "Stopped."; exit 1' INT TERM

{
	echo "Mac: $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $CPUS CPUs"
	echo "CPU family: $(sysctl -n hw.cpufamily)"
	echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
	echo "Power: $(pmset -g batt | head -1)"
	echo "Started: $(date)"
	echo
	as_owner "$APP" --report 2>&1 | sed -n '1,/^GPUs:/p'
} > "$OUT/about.txt"

# powermetrics, with the arguments Power Gauge asks for first, and --show-plimits too if this
# Mac's powermetrics takes it.
if [ $DRY -eq 0 ]; then
	ARGS=(--samplers cpu_power,gpu_power,smc --show-extra-power-info --hide-cpu-duty-cycle -f plist -i 1000)
	if /usr/bin/powermetrics "${ARGS[@]}" --show-plimits -n 1 > /dev/null 2>&1; then ARGS+=(--show-plimits)
	elif ! /usr/bin/powermetrics "${ARGS[@]}" -n 1 > /dev/null 2>&1; then ARGS=(--samplers cpu_power,smc -f plist -i 1000); fi
	echo "${ARGS[*]}" > "$OUT/arguments.txt"
	/usr/bin/powermetrics "${ARGS[@]}" > "$OUT/powermetrics.plist" 2> "$OUT/powermetrics-errors.txt" &
	PM=$!
fi

# Once a second, what macOS says.
XCPM=(hard_plimit_max_100mhz_ratio soft_plimit_max_100mhz_ratio lpm_plimit_max_100mhz_ratio lpm_enabled cpu_thermal_level gpu_thermal_level io_thermal_level)
therm() { pmset -g therm 2> /dev/null | awk -F'= *' -v key="$1" '$0 ~ key {print $2; exit}'; }
(
	printf 'time\tscenario\tspeed_limit\tscheduler_limit\tavailable_cpus\tlow_power_mode'
	printf '\t%s' "${XCPM[@]}"
	printf '\n'
	while true; do
		printf '%s\t%s\t%s\t%s\t%s\t%s' "$(date +%s)" "$(cat "$OUT/.scenario" 2> /dev/null || true)" \
			"$(therm CPU_Speed_Limit)" "$(therm CPU_Scheduler_Limit)" "$(therm CPU_Available_CPUs)" \
			"$(pmset -g 2> /dev/null | awk '/lowpowermode/ {print $2; exit}')"
		for K in "${XCPM[@]}"; do printf '\t%s' "$(sysctl -n "machdep.xcpm.$K" 2> /dev/null || true)"; done
		printf '\n'
		sleep 1
	done
) > "$OUT/system.tsv" &
LOGGER=$!

printf 'start\tend\tscenario\n' > "$OUT/scenarios.tsv"
# Runs one scenario: a name, seconds, then how many CPUs to keep busy and which GPU, if any.
scenario() {
	local NAME="$1" SECONDS_FOR="$2" BUSY="${3:-0}" GPU="${4:-}" N=0
	if [ $DRY -eq 1 ]; then SECONDS_FOR=2; fi
	echo "$NAME" > "$OUT/.scenario"
	printf '%-28s %3d s\n' "$NAME" "$SECONDS_FOR"
	local START; START="$(date +%s)"
	# Counted with a loop, since macOS's seq counts down: "seq 1 0" gives 1 and 0, not nothing.
	while [ $N -lt "$BUSY" ]; do yes > /dev/null & LOADS+=($!); N=$((N + 1)); done
	if [ -n "$GPU" ]; then
		if [ "$GPU" = integrated ]; then as_owner "$APP" --gpu-load "$SECONDS_FOR" integrated > /dev/null & else as_owner "$APP" --gpu-load "$SECONDS_FOR" > /dev/null & fi
		LOADS+=($!)
	fi
	sleep "$SECONDS_FOR"
	stop_loads
	printf '%s\t%s\t%s\n' "$START" "$(date +%s)" "$NAME" >> "$OUT/scenarios.tsv"
}

echo "Recording to $OUT; $([ $DRY -eq 1 ] && echo "about 20 seconds, as a dry run" || echo "about 6 minutes. Leave the Mac alone")."
scenario idle 30
scenario "one CPU busy" 30 1
scenario "half the CPUs busy" 30 $((CPUS / 2))
scenario "every CPU busy" 90 "$CPUS"
scenario rest 20
scenario "integrated GPU busy" 30 0 integrated
scenario "every CPU and integrated GPU" 45 "$CPUS" integrated
scenario "other GPU busy" 30 0 discrete
scenario "cool down" 30
rm -f "$OUT/.scenario"
echo "Done. The survey is in $(pwd)/$OUT"
