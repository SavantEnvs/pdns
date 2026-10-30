#!/usr/bin/env bash
#
# mayhem/build.sh — build the PowerDNS fuzz harnesses (auth + dnsdist, as OSS-Fuzz does), their
# `-standalone` reproducers, and the auth unit-test runner used by mayhem/test.sh.
#
# Everything builds out-of-tree with meson into mayhem/build-*/ (gitignored via mayhem/.gitignore),
# so upstream's tree is never modified. All dependencies are apt -dev packages baked in the image
# (see mayhem/Dockerfile): nothing is fetched, so the build is air-gapped and re-runnable.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT="$SRC"
B="$SRC/mayhem/build-fuzz"            # object/link scratch for the sanitized builds
mkdir -p "$B"

# ---- harness list: <binary name>:<dir holding the meson project>:<meson target> -----------------
# Binaries are lower-cased copies of the meson targets (Mayhem target slugs are lower-case).
AUTH_TARGETS="dnspacketroundtrip moadnsparser packetcache proxyprotocol dnslabeltext-parseRFC1035CharString yahttp recordcontent zoneparsertng"
DNSDIST_TARGETS="dnsdist-dnsparser dnsdistcache dnsdist-ecs"

# ---- LSan off + standalone driver objects (SPEC §6.2 item 15; common.md) -----------------------
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/lsan_off.o"
# The standalone driver is C: compile it as C so its LLVMFuzzerTestOneInput reference keeps C linkage.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"
FUZZER_NO_MAIN="$($CC -print-file-name=libclang_rt.fuzzer_no_main-x86_64.a)"

# ---- 1) sanitized, instrumented fuzz builds (project + harness) ---------------------------------
# -fsanitize=fuzzer-no-link instruments the project for libFuzzer coverage; the libFuzzer engine is
# linked in through meson's `fuzzer_ldflags`. -O1 matches the OSS-Fuzz-era recipe.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1"
FUZZ_LDFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $B/lsan_off.o"

meson_fuzz() {  # <source dir> <build dir> <meson args...>
  local srcdir="$1" bdir="$2"; shift 2
  if [ ! -f "$bdir/build.ninja" ]; then
    (cd "$srcdir" && CFLAGS="$FUZZ_CFLAGS" CXXFLAGS="$FUZZ_CFLAGS" LDFLAGS="$FUZZ_LDFLAGS" \
       meson setup "$bdir" --buildtype=plain -Dhardening=disabled -Db_pie=false \
         -Dfuzz-targets=true "-Dfuzzer_ldflags=$LIB_FUZZING_ENGINE" "$@")
  fi
}

# install_pair <build dir> <meson target>: the libFuzzer binary + its run-once -standalone twin.
install_pair() {
  local bdir="$1" tgt="$2" name
  name="$(printf '%s' "fuzz-target-$tgt" | tr 'A-Z' 'a-z')"
  cp "$bdir/fuzz-target-$tgt" "$OUT/$name"
  # Re-run the exact meson link line, swapping the libFuzzer engine for the standalone driver.
  (cd "$bdir" && ninja -t commands "fuzz-target-$tgt" | tail -n 1 \
     | sed -e "s# -o fuzz-target-$tgt # -o $OUT/$name-standalone #" \
           -e "s# $LIB_FUZZING_ENGINE # $B/standalone_main.o $FUZZER_NO_MAIN #" \
     | bash)
}

AUTH_B="$B/auth"
meson_fuzz "$SRC" "$AUTH_B" -Dlua-records=false -Dunit-tests=false -Dtools=false -Dtls-gnutls=disabled
(cd "$AUTH_B" && ninja -j"$MAYHEM_JOBS" $(for t in $AUTH_TARGETS; do printf 'fuzz-target-%s ' "$t"; done))
for t in $AUTH_TARGETS; do install_pair "$AUTH_B" "$t"; done

DD_B="$B/dnsdist"
meson_fuzz "$SRC/pdns/dnsdistdist" "$DD_B" -Dunit-tests=false -Dyaml=disabled -Dlibedit=disabled -Dman-pages=false
(cd "$DD_B" && ninja -j"$MAYHEM_JOBS" $(for t in $DNSDIST_TARGETS; do printf 'fuzz-target-%s ' "$t"; done))
for t in $DNSDIST_TARGETS; do install_pair "$DD_B" "$t"; done

# ---- 2) the authoritative server's own unit-test suite, NORMAL flags (mayhem/test.sh only runs it) --
TB="$SRC/mayhem/build-test"
if [ ! -f "$TB/build.ninja" ]; then
  (cd "$SRC" && CFLAGS="-O1 $COVERAGE_FLAGS" CXXFLAGS="-O1 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
     meson setup "$TB" --buildtype=plain -Db_pie=false -Dunit-tests=true -Dtools=false)
fi
(cd "$TB" && ninja -j"$MAYHEM_JOBS" pdns-auth-testrunner)
