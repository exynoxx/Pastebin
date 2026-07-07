#!/usr/bin/env bash
# Build the bench load generator + benchserver in each memory-management mode.
# Binaries land in bench/bin/ (gitignored). Run build.sh once, then run.sh.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
out="$here/bin"; mkdir -p "$out"
common=(-d:release --hints:off --warnings:off)

nim c "${common[@]}" -o:"$out/loadgen" "$here/loadgen.nim"

# One benchserver per mm mode so run.sh can compare orc (production default) vs arc vs atomicArc.
for mm in orc arc atomicArc; do
    nim c "${common[@]}" --mm:"$mm" -o:"$out/benchserver_$mm" "$here/benchserver.nim"
done

# Profile-friendly build (frame pointers + line info) so `perf` attributes samples to Nim procs.
nim c "${common[@]}" --mm:atomicArc --debuginfo:on --lineDir:on \
    --passC:-fno-omit-frame-pointer -o:"$out/benchserver_perf" "$here/benchserver.nim"

# orc + frame pointers: same optimizer, but the wider stack frame widens the (always-present)
# cycle-collector race window so the crash test surfaces the SIGSEGV reliably on x86. The plain
# benchserver_orc above has the identical race with a narrower window (and aarch64's weaker memory
# ordering widens it again in production).
nim c "${common[@]}" --mm:orc --debuginfo:on --lineDir:on \
    --passC:-fno-omit-frame-pointer -o:"$out/benchserver_orc_fp" "$here/benchserver.nim"

echo "built: $(ls "$out")"
