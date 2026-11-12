#!/usr/bin/env bash
# Runs the script against stub gcloud/curl (tests/stubs). Nothing touches GCP.
# Usage: tests/run.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../redpanda-gcp-reserve.sh"
export PATH="$here/stubs:$PATH"

passed=0; failed=0
out=""; rc=0

setup() {
  STUB_STATE="$(mktemp -d)"; export STUB_STATE
  unset STUB_CPU_FREE STUB_SSD_FREE STUB_STOCKOUTS STUB_CREATE_ERROR STUB_NO_AUTH STUB_NO_PERMS
}
run() { out="$("$script" "$@" 2>&1)"; rc=$?; }
ok()  { passed=$((passed + 1)); printf '  ok    %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf '  FAIL  %s\n' "$1"; printf '%s\n' "$out" | sed 's/^/        | /'; }
expect_rc()       { if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $rc, want $2)"; fi; }
expect_out()      { if printf '%s' "$out" | grep -qE -- "$2"; then ok "$1"; else bad "$1 (no match for /$2/)"; fi; }
expect_no_out()   { if printf '%s' "$out" | grep -qE -- "$2"; then bad "$1 (unexpected /$2/)"; else ok "$1"; fi; }
expect_files()    { if [ "$(count_files)" -eq "$2" ]; then ok "$1"; else bad "$1 ($(count_files) reservations, want $2)"; fi; }
count_files()     { find "$STUB_STATE" -maxdepth 1 -type f ! -name '.*' | wc -l | tr -d ' '; }

P=(--project test-project)

echo "args"
setup
run --help;                          expect_rc  "--help exits 0" 0
                                     expect_out "--help lists options" "--headroom-nodes"
                                     expect_out "--help shows the header" "Reserve Compute Engine capacity"
run check;                           expect_rc  "missing --project fails" 1
run check "${P[@]}" --vm-count two;         expect_rc  "non-numeric --vm-count fails" 1
run check "${P[@]}" --ssd-interface sata;   expect_rc  "bad --ssd-interface fails" 1
run create "${P[@]}" --simulate-stockout 1; expect_rc  "--simulate-stockout without --dry-run fails" 1
run check "${P[@]}" --bogus;                expect_rc  "unknown flag fails" 1

echo "check"
setup
run check "${P[@]}" --region us-east4
expect_rc     "check passes with plenty of quota" 0
expect_out    "zones are expanded from suffixes" "us-east4-a us-east4-b us-east4-c"
expect_out    "prints the create command" "gcloud compute reservations create redpanda-tier5-b --project=test-project --zone=us-east4-b --vm-count=2 --machine-type=n2d-standard-16 --local-ssd=count=16,size=375,interface=nvme"
expect_out    "next step keeps the flags" "create --project test-project --region us-east4"
expect_files "check creates nothing" 0

setup; export STUB_CPU_FREE=100   # covers 96 reserved, not 96 + 3*16 headroom
run check "${P[@]}"
expect_rc     "check passes when only headroom is short" 0
expect_out    "warns about headroom" "WARN.*N2D_CPUS.*headroom"

setup; export STUB_CPU_FREE=50
run check "${P[@]}"
expect_rc     "check fails when the reservation doesn't fit quota" 1
expect_out    "says which quota" "FAIL.*N2D_CPUS: reservation needs 96"

setup; export STUB_NO_AUTH=1
run check "${P[@]}"
expect_rc     "check fails on expired credentials" 1
expect_out    "tells you to gcloud auth login" "gcloud auth login"

setup; export STUB_NO_PERMS=1
run check "${P[@]}"
expect_rc     "check fails without reservation permissions" 1
expect_out    "names the missing permissions" "missing IAM permissions"

echo "create --dry-run"
setup
run create "${P[@]}" --dry-run --simulate-stockout 2 --retry-interval 0
expect_rc     "dry run exits 0" 0
expect_out    "retries simulated stockouts" "us-central1-c: attempt 3"
expect_out    "reports completion" "Dry run complete"
expect_files "dry run creates nothing" 0

echo "create (against the stub)"
setup; export STUB_STOCKOUTS=2
run create "${P[@]}" --retry-interval 0
expect_rc     "create exits 0 once every zone lands" 0
expect_out    "retries stockouts" "out of stock"
expect_out    "status shows all zones held" "All zones hold 2 VMs"
expect_files "three reservations exist" 3

run create "${P[@]}" --retry-interval 0
expect_out    "re-run skips existing reservations" "already exists, skipping"

setup; export STUB_STOCKOUTS=5
run create "${P[@]}" --retry-interval 0 --max-attempts 2
expect_out    "gives up after --max-attempts" "giving up after 2 attempts"

setup; export STUB_CREATE_ERROR=1
run create "${P[@]}" --retry-interval 0
expect_rc     "non-stockout error exits 1" 1
expect_out    "says it won't retry" "not retrying"

setup; export STUB_CREATE_ERROR=capacity
run create "${P[@]}" --zones a --retry-interval 0
expect_rc     "reservation capacity limit exits 1" 1
expect_out    "explains the capacity limit" "Reserve before the VMs"

echo "no local SSD (--ssd-count 0)"
setup
run check "${P[@]}" --zones a --ssd-count 0
expect_rc     "check passes with no local SSD" 0
expect_out    "spec says no local SSD" "no local SSD"
expect_no_out "no local SSD quota check" "LOCAL_SSD_TOTAL_GB"
expect_no_out "planned command has no --local-ssd" "--local-ssd"
run create "${P[@]}" --zones a --ssd-count 0 --retry-interval 0
expect_rc     "create with --ssd-count 0 exits 0" 0
expect_files  "one reservation exists" 1

echo "status / delete"
setup
run status "${P[@]}"
expect_out    "status before create" "not created"
export STUB_STOCKOUTS=0
run create "${P[@]}" --retry-interval 0 --zones a,b
run delete "${P[@]}" --zones a,b --yes
expect_rc     "delete --yes exits 0" 0
expect_files "delete removes the reservations" 0
run delete "${P[@]}" --zones a --yes
expect_out    "delete skips missing reservations" "not found, skipping"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
