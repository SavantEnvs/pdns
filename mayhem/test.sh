#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN the authoritative server's Boost.Test suite (pdns-auth-testrunner, built with NORMAL flags by
# mayhem/build.sh). It asserts behavior: ~290 test cases / ~860k assertions over DNS name handling,
# wire parsing/writing, record content, zone parsing, DNSSEC signers, TSIG, packet cache, ... Some
# cases read zone files relative to pdns/, hence the cd.
RUNNER="$SRC/mayhem/build-test/pdns-auth-testrunner"
[ -x "$RUNNER" ] || { echo "FATAL: $RUNNER missing — mayhem/build.sh must build it" >&2; emit_ctrf "boost-test" 0 1 0; exit 1; }
cd "$SRC/pdns"
OUTF="$(mktemp)"
BOOST_TEST_LOG_LEVEL=message "$RUNNER" --report_level=short >"$OUTF" 2>&1
cat "$OUTF"

# Boost.Test's summary: "N test cases out of M passed", "... passed with warnings", "... failed",
# "... aborted", "... skipped". A neutered/empty runner prints no summary -> everything parses to 0
# and we report a failure instead of a pass.
count() { grep -E "test cases out of [0-9]+ $1\$" "$OUTF" | tail -n1 | awk '{print $1}'; }
total="$(grep -oE 'test cases out of [0-9]+' "$OUTF" | tail -n1 | awk '{print $5}')"
passed="$(count passed)"; warned="$(count 'passed with warnings')"
failed="$(count failed)"; aborted="$(count aborted)"; skipped="$(count skipped)"
passed=$(( ${passed:-0} + ${warned:-0} )); failed=$(( ${failed:-0} + ${aborted:-0} )); skipped=${skipped:-0}
total=${total:-0}
if [ "$total" -eq 0 ] || [ $(( passed + failed + skipped )) -ne "$total" ]; then
  echo "FATAL: could not account for the Boost.Test results (total=$total passed=$passed failed=$failed skipped=$skipped)" >&2
  failed=$(( failed + 1 ))
fi
emit_ctrf "boost-test" "$passed" "$failed" "$skipped"
