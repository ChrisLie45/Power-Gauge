#!/bin/bash
# Runs the script that monitoring runs as root (RootScript.text), as this user instead,
# with a stand-in for powermetrics and a scratch folder in place of /tmp, through five cases:
#   stop     the stop file stops powermetrics, ends the stream and removes the folder
#   dies     a powermetrics that exits after running for 4 s ends the stream, and no other
#            set of arguments is tried
#   rejects  sets of arguments that powermetrics turns down at once are passed over for the
#            next, plainer set
#   gone     an app that quit while the password prompt was up: the script does nothing
#   unread   an app that quits before it opens the stream: nothing is left waiting on it
# Prints "ok <case>" or "FAIL <case>: <why>" for each, and exits 1 if any failed.
#   Tests/root-script.sh <app executable> <scratch folder>
set -uo pipefail
APP="$1" WORK="$2"
case "$WORK" in *[[:space:]\'\"]*) echo "FAIL setup: the scratch folder's path must have no spaces or quotes"; exit 1 ;; esac
mkdir -p "$WORK/tmp"
FAKE="$WORK/powermetrics"
cat > "$FAKE" <<'EOF'
#!/bin/bash
# Stands in for powermetrics: notes its arguments in $LOG, exits at once if they contain
# $REJECT, and otherwise writes an empty plist document every half second, until it is
# stopped or $DIE_AFTER seconds have passed.
echo "$*" >> "$LOG"
if [ -n "${REJECT:-}" ] && [[ "$*" == *"$REJECT"* ]]; then echo "rejected: $*" >&2; exit 1; fi
END=$(( $(date +%s) + ${DIE_AFTER:-100000} ))
while [ "$(date +%s)" -lt "$END" ]; do
	printf '<?xml version="1.0"?><plist version="1.0"><dict></dict></plist>\n'
	sleep 0.5
done
EOF
chmod +x "$FAKE"

FAILED=0
result() { if [ -z "$2" ]; then echo "ok $1"; else echo "FAIL $1: $2"; FAILED=1; fi; }

# Starts the script for a case, with the environment given, and reads its stream in the
# background as the app would. This shell stands in for the app, whose process it watches,
# unless $APP_PID names another; with $UNREAD set, nothing reads the stream.
start() {
	NAME="$1"; shift
	STOP="$WORK/stop-$NAME" LOG="$WORK/$NAME.log"
	rm -f "$STOP" "$LOG"
	SCRIPT="$("$APP" --root-script "${APP_PID:-$$}" "$STOP")"
	SCRIPT="${SCRIPT//\/usr\/bin\/powermetrics/$FAKE}"
	SCRIPT="${SCRIPT//\/tmp\/powergauge/$WORK/tmp/powergauge}"
	DIR="$(env LOG="$LOG" "$@" /bin/sh -c "$SCRIPT")"
	STATUS=$?
	[ -n "${UNREAD:-}" ] || [ -z "$DIR" ] && return
	cat "$DIR/stream" > "$WORK/$NAME.out" &
	READER=$!
}

# Waits up to $1 seconds for the stream to end, as it does when powermetrics has gone.
ended() {
	local until=$((SECONDS + $1))
	while kill -0 "$READER" 2>/dev/null; do
		[ $SECONDS -ge "$until" ] && return 1
		sleep 0.2
	done
}

# Waits up to $1 seconds for the root-owned folder to be removed.
removed() {
	local until=$((SECONDS + $1))
	while [ -d "$DIR" ]; do
		[ $SECONDS -ge "$until" ] && return 1
		sleep 0.2
	done
}

running() { pgrep -f "$FAKE" > /dev/null; }

# Waits up to $1 seconds for every shell the script started to be gone.
shells_gone() {
	local until=$((SECONDS + $1))
	while pgrep -f "$WORK/tmp/powergauge" > /dev/null; do
		[ $SECONDS -ge "$until" ] && return 1
		sleep 0.2
	done
}

start stop
sleep 2
touch "$STOP"
WHY=""
ended 4 || WHY="the stream did not end within 4 s of the stop file appearing"
[ -z "$WHY" ] && ! removed 3 && WHY="the folder was not removed"
[ -z "$WHY" ] && running && WHY="powermetrics was still running"
[ -z "$WHY" ] && [ "$(grep -c "</plist>" "$WORK/stop.out")" -lt 2 ] && WHY="the stream carried fewer than 2 samples"
[ -z "$WHY" ] && [ "$(wc -l < "$LOG")" -ne 1 ] && WHY="powermetrics was started $(wc -l < "$LOG" | tr -d ' ') times, not once"
result stop "$WHY"
pkill -f "$FAKE"

start dies DIE_AFTER=4
WHY=""
ended 9 || WHY="the stream did not end after powermetrics exited"
[ -z "$WHY" ] && [ "$(wc -l < "$LOG")" -ne 1 ] && WHY="powermetrics was started $(wc -l < "$LOG" | tr -d ' ') times after it exited by itself, not once"
# The app marks the stream's end with the stop file, after which the folder goes.
touch "$STOP"
[ -z "$WHY" ] && ! removed 3 && WHY="the folder was not removed after the stream ended"
result dies "$WHY"
pkill -f "$FAKE"

start rejects REJECT=gpu_power
sleep 2
WHY=""
[ "$(wc -l < "$LOG")" -ne 3 ] && WHY="expected 3 starts, two turned down, got $(wc -l < "$LOG" | tr -d ' ')"
[ -z "$WHY" ] && [ "$(sed -n 3p "$LOG")" != "--samplers cpu_power,smc --show-extra-power-info --hide-cpu-duty-cycle -f plist -b 1 -i 1000" ] && WHY="the third start had the arguments: $(sed -n 3p "$LOG")"
touch "$STOP"
[ -z "$WHY" ] && ! ended 4 && WHY="the stream did not end after the stop file appeared"
[ -z "$WHY" ] && ! removed 3 && WHY="the folder was not removed"
result rejects "$WHY"
pkill -f "$FAKE"

# A process that has already ended stands in for the app.
sleep 0 &
APP_PID=$!
wait $APP_PID
start gone
WHY=""
[ "$STATUS" -eq 0 ] && WHY="the script went ahead, printing \"$DIR\""
[ -z "$WHY" ] && ! shells_gone 3 && WHY="a shell was left running"
[ -z "$WHY" ] && [ -e "$LOG" ] && WHY="powermetrics was started"
result gone "$WHY"
unset APP_PID

# An app that quits after a second without opening the stream.
sleep 1 &
APP_PID=$!
UNREAD=1 start unread
wait $APP_PID
WHY=""
shells_gone 5 || WHY="a shell was left waiting on the stream: $(pgrep -fl "$WORK/tmp/powergauge" | cut -c1-40)"
[ -z "$WHY" ] && ! removed 3 && WHY="the folder was not removed"
[ -z "$WHY" ] && [ -e "$LOG" ] && WHY="powermetrics was started"
result unread "$WHY"
unset APP_PID
pkill -f "$WORK/tmp/powergauge"
pkill -f "$FAKE"
exit $FAILED
