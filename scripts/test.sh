#!/bin/bash
# Runs the tests: builds the app, then checks its test modes against what Tests/ expects.
#   scripts/test.sh              build, then run every test
#   scripts/test.sh --no-build   test the app already in build/
#   scripts/test.sh --update     record what the app does now as expected, after a change
#                                you meant
# The tests:
#   parse      each powermetrics file in Tests/fixtures reads as Tests/expected/parse says: a real
#              sample, and variants of it as powermetrics gives them with fewer arguments, with
#              no per-CPU tables, while throttled, and three in one stream
#   csv        recording the stream writes Tests/expected/recording.csv
#   print      --print-csv prints the stream's samples to standard output, with no window, as
#              Tests/expected/printed.txt has them, and stops at once on Ctrl-C
#   help       --help and -h print the options and exit, before any test mode or the app
#   limit-kinds  each limit reason in Tests/limit-reasons.txt is taken for the kind
#              Tests/expected/limit-kinds.txt says: thermal, power or normal
#   kernel-windows  made-up readings of the kernel's statistics, normal and each kind that can't
#              be trusted, give what Tests/expected/kernel-windows.txt says
#   kernel     this Mac's kernel statistics can be read and hold together for a few seconds;
#              where they can't be, under Rosetta or in a virtual machine such as a build
#              server's, the check says why and passes
#   survey-…   each throttle survey in Tests/fixtures (scripts/throttle-survey.sh, trimmed to
#              what the app reads) replays, second by second, to the states its expected file
#              lists for each scenario: what the app would have said on that Mac
#   root script  the script monitoring runs as root stops when asked, ends when powermetrics
#              dies, passes over sets of arguments that powermetrics turns down, does nothing
#              once the app has gone, and leaves nothing waiting on a stream no one reads; it is
#              run as this user, with a stand-in for powermetrics (Tests/root-script.sh)
#   app        the real app, offscreen, with made-up kernel statistics and that stand-in:
#              monitoring from the kernel, falling back to powermetrics when its readings stop
#              holding together, menus, the menu bar menu, recording, stop, restart, powermetrics
#              failing, choosing powermetrics, quitting
# A test that logs "Unable to simultaneously satisfy constraints" fails. Nothing is shown on
# screen, nothing needs privileges, and the app's saved settings are left alone.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=1 UPDATE=0
for ARG in "$@"; do
	case "$ARG" in
	--no-build) BUILD=0 ;;
	--update) UPDATE=1 ;;
	*) echo "usage: $0 [--no-build] [--update]" >&2; exit 2 ;;
	esac
done

[ $BUILD -eq 1 ] && scripts/build.sh
APP="build/Power Gauge.app/Contents/MacOS/PowerGauge"
OUT=build/tests
rm -rf build/tests
mkdir -p "$OUT" Tests/expected

PASSED=0 FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "  ok    $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL  $1"; [ -z "${2:-}" ] || echo "$2" | sed 's/^/        /'; }

# Counts a line of "ok <step>" or "FAIL <step>: <why>" from a check that runs several steps.
report() {
	case "$1" in
	"ok "*) pass "${1#ok }" ;;
	"FAIL "*) local REST="${1#FAIL }"; fail "${REST%%: *}" "${REST#*: }" ;;
	esac
}

# Fails a test whose standard error has a constraint conflict in it.
conflicts() { grep -q "Unable to simultaneously satisfy constraints" "$1"; }

# Runs a check that reports several steps, keeping its exit status as well as its output.
# A crash or an empty report must fail even if the child never printed a FAIL line.
check_steps() {
	local NAME="$1" STATUS=0 BEFORE=$((PASSED + FAILED)) BEFORE_FAILED=$FAILED LINE
	shift
	"$@" > "$OUT/$NAME.txt" 2> "$OUT/$NAME.err" || STATUS=$?
	while IFS= read -r LINE || [ -n "$LINE" ]; do report "$LINE"; done < "$OUT/$NAME.txt"
	if [ $STATUS -ne 0 ] && [ $FAILED -eq $BEFORE_FAILED ]; then
		fail "$NAME" "exited with status $STATUS; see $OUT/$NAME.txt and $OUT/$NAME.err"
	elif [ $((PASSED + FAILED)) -eq $BEFORE ]; then
		fail "$NAME" "reported no test results; see $OUT/$NAME.txt and $OUT/$NAME.err"
	fi
	if conflicts "$OUT/$NAME.err"; then
		fail "$NAME" "logged a constraint conflict; see $OUT/$NAME.err"
	fi
}

# Compares a test mode's output with the expected file, or records it with --update.
check_text() {
	local NAME="$1" EXPECTED="$2"; shift 2
	if ! "$APP" "$@" > "$OUT/$NAME.txt" 2> "$OUT/$NAME.err"; then
		fail "$NAME" "exited with an error: $(cat "$OUT/$NAME.err")"
	elif conflicts "$OUT/$NAME.err"; then
		fail "$NAME" "logged a constraint conflict; see $OUT/$NAME.err"
	elif [ $UPDATE -eq 1 ]; then
		cp "$OUT/$NAME.txt" "$EXPECTED"
		pass "$NAME (recorded)"
	elif diff -u "$EXPECTED" "$OUT/$NAME.txt" > "$OUT/$NAME.diff"; then
		pass "$NAME"
	else
		fail "$NAME" "differs from $EXPECTED:
$(head -20 "$OUT/$NAME.diff")"
	fi
}

echo "Readings"
mkdir -p Tests/expected/parse
for FIXTURE in Tests/fixtures/*.plist; do
	NAME="$(basename "$FIXTURE" .plist)"
	# The mbp2014 samples are from a Haswell processor, which lays out its limit bits its own way.
	LAYOUT=skylake
	case "$NAME" in *mbp2014*) LAYOUT=haswell ;; esac
	check_text "parse-${NAME#powermetrics-}" "Tests/expected/parse/$NAME.txt" --parse "$FIXTURE" --layout "$LAYOUT"
done
check_text csv Tests/expected/recording.csv --csv-check Tests/fixtures/powermetrics-stream.plist
# Printing the stream with no window (--print-csv): the CPU columns of the header, then for each
# sample what came from it, leaving out what the app reads from this Mac as it goes, macOS's
# limits among them.
if "$APP" --print-csv --stream Tests/fixtures/powermetrics-stream.plist > "$OUT/printed.csv" 2> "$OUT/printed.err"; then
	{ head -1 "$OUT/printed.csv" | cut -d, -f1-30; awk -F, 'NR > 1 && $3 != ""' "$OUT/printed.csv" | cut -d, -f3-10,28-30; } > "$OUT/printed.txt"
	if [ $UPDATE -eq 1 ]; then
		cp "$OUT/printed.txt" Tests/expected/printed.txt
		pass "print (recorded)"
	elif diff -u Tests/expected/printed.txt "$OUT/printed.txt" > "$OUT/printed.diff"; then
		pass "print"
	else
		fail "print" "differs from Tests/expected/printed.txt:
$(head -20 "$OUT/printed.diff")"
	fi
else
	fail "print" "exited with an error: $(cat "$OUT/printed.err")"
fi
# Ctrl-C ends printing as quitting does: at once, with every row written whole. The stream is a
# pipe kept open, so that only the signal can end it.
mkfifo "$OUT/feed"
(cat Tests/fixtures/powermetrics-stream.plist; sleep 30) > "$OUT/feed" 2> /dev/null &
FEEDER=$!
"$APP" --print-csv --stream "$OUT/feed" > "$OUT/interrupted.csv" 2> "$OUT/interrupted.err" &
PRINTER=$!
sleep 2
kill -INT $PRINTER
WAITED=0
while kill -0 $PRINTER 2>/dev/null && [ $WAITED -lt 30 ]; do sleep 0.1; WAITED=$((WAITED + 1)); done
if kill -0 $PRINTER 2>/dev/null; then
	kill -9 $PRINTER
	fail "print stops on Ctrl-C" "still running 3 s after SIGINT"
elif ! wait $PRINTER; then
	fail "print stops on Ctrl-C" "exited with an error: $(cat "$OUT/interrupted.err")"
elif [ "$(tail -c1 "$OUT/interrupted.csv" | xxd -p)" != 0a ] || [ "$(awk -F, '$3 != ""' "$OUT/interrupted.csv" | wc -l)" -ne 4 ]; then
	fail "print stops on Ctrl-C" "expected a header and 3 whole rows of samples, got: $(cut -c1-60 "$OUT/interrupted.csv")"
else
	pass "print stops on Ctrl-C"
fi
pkill -P $FEEDER 2>/dev/null; kill $FEEDER 2>/dev/null || true
# --help and -h print the options and exit before any test mode or the app, whatever other flags
# come with them. Those flags end at once on their own too, so a broken help fails here instead
# of starting monitoring.
if "$APP" --print-csv --stream /dev/null --help > "$OUT/help.txt" 2> "$OUT/help.err" \
	&& "$APP" --kernel-windows -h > "$OUT/help-short.txt" 2>> "$OUT/help.err" \
	&& head -1 "$OUT/help.txt" | grep -q '^Usage: ' && cmp -s "$OUT/help.txt" "$OUT/help-short.txt"; then
	pass "help"
else
	fail "help" "expected the same options from --help and -h, and a status of 0; see $OUT/help.txt and help-short.txt: $(cat "$OUT/help.err")"
fi
for SURVEY in Tests/fixtures/survey-*/; do
	NAME="$(basename "$SURVEY")"
	check_text "$NAME" "Tests/expected/$NAME.txt" --survey-check "$SURVEY"
done
# shellcheck disable=SC2046
check_text limit-kinds Tests/expected/limit-kinds.txt --classify $(grep -v '^#' Tests/limit-reasons.txt)
check_text kernel-windows Tests/expected/kernel-windows.txt --kernel-windows
check_steps kernel "$APP" --kernel-check

echo "Root script"
# Runs it as this user, with a stand-in for powermetrics; see Tests/root-script.sh.
check_steps root Tests/root-script.sh "$(pwd)/$APP" "$(pwd)/$OUT/root"

echo "App"
check_steps app "$APP" --app-check "$(pwd)/Tests/fixtures/powermetrics-mbp2019-power.plist"

echo "$PASSED passed, $FAILED failed"
[ $FAILED -eq 0 ]
