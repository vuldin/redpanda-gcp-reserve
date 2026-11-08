#!/usr/bin/env bash
#
# redpanda-gcp-reserve.sh
#
# Reserve Compute Engine capacity in your own GCP project, so that a Redpanda
# BYOC tier change or new cluster can still get its nodes during a zonal
# stockout. Redpanda's GKE node pools use any matching reservation
# automatically (reservation affinity "any"). The reservation shape therefore
# has to match the tier's node shape exactly.
#
# Defaults match BYOC tier 5 (tier-5-gcp-v2-x86) across us-central1-a/b/c:
#   n2d-standard-16, 16 x 375 GB NVMe local SSD, 2 VMs per zone (6 total).
#
# Subcommands:
#   check   (default) Read-only preflight. Validates auth, permissions, zones,
#           machine type, quota and existing reservations, then prints the
#           exact create commands. Creates nothing.
#   create  Create one reservation per zone, retrying zones that are out of
#           stock until they succeed or --max-attempts is reached.
#           Add --dry-run to walk through the whole flow without creating
#           anything (use --simulate-stockout N to exercise the retry path).
#   status  Show the reservations this script manages and how many VMs use them.
#   delete  Delete the reservations this script manages (asks to confirm).
#
# Billing: GCP bills a reservation as running VMs from the moment it exists,
# whether or not anything uses it. Create it right before you need the nodes.
#
# Works with the bash 3.2 that ships on macOS.

set -uo pipefail

# ---- defaults ---------------------------------------------------------------
PROJECT=""
REGION="us-central1"
ZONES="a,b,c"
VM_COUNT=2
MACHINE_TYPE="n2d-standard-16"
SSD_COUNT=16
SSD_SIZE=375
SSD_INTERFACE="nvme"
PREFIX="redpanda-tier5"
RETRY_INTERVAL=60
MAX_ATTEMPTS=120
HEADROOM_NODES=3
DRY_RUN=0
SIMULATE_STOCKOUT=0
ASSUME_YES=0
CMD="check"

# ---- output helpers ---------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_DIM=""; C_OFF=""
fi
FAILS=0
WARNS=0
pass() { printf '  %sPASS%s  %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$C_YLW" "$C_OFF" "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '  %sFAIL%s  %s\n' "$C_RED" "$C_OFF" "$*"; FAILS=$((FAILS + 1)); }
info() { printf '  %s....%s  %s\n' "$C_DIM" "$C_OFF" "$*"; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
ts()   { date '+%Y-%m-%d %H:%M:%S'; }

usage() {
  # Print the header comment block (everything after the shebang up to the first code line).
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  echo
  cat <<EOF
Options:
  --project ID            GCP project that hosts the BYOC cluster (required)
  --region REGION         default: $REGION
  --zones LIST            zone suffixes or full names, comma separated (default: $ZONES)
  --vm-count N            VMs to reserve per zone (default: $VM_COUNT)
  --machine-type TYPE     default: $MACHINE_TYPE
  --ssd-count N           local SSDs per VM (default: $SSD_COUNT)
  --ssd-size GB           size of each local SSD (default: $SSD_SIZE)
  --ssd-interface IF      nvme or scsi (default: $SSD_INTERFACE)
  --prefix NAME           reservation name prefix; one per zone: <prefix>-<zone> (default: $PREFIX)
  --retry-interval SEC    wait between passes over out-of-stock zones (default: $RETRY_INTERVAL)
  --max-attempts N        attempts per zone before giving up, 0 = forever (default: $MAX_ATTEMPTS)
  --headroom-nodes N      extra nodes of quota Redpanda needs for maintenance; warns if quota
                          can't cover the reservation plus this many nodes (default: $HEADROOM_NODES)
  --dry-run              create: print commands and simulate success instead of creating
  --simulate-stockout N   with --dry-run: fail each zone's first N attempts with a fake stockout
  --yes                   delete: skip the confirmation prompt
  -h, --help

Examples:
  $0 check  --project my-project
  $0 create --project my-project --dry-run --simulate-stockout 2 --retry-interval 5
  $0 create --project my-project
  $0 create --project my-project --region us-east4 --zones a,b,c --max-attempts 0
  $0 status --project my-project
  $0 delete --project my-project
EOF
}

# ---- args -------------------------------------------------------------------
if [ $# -gt 0 ]; then
  case "$1" in
    check|create|status|delete) CMD="$1"; shift ;;
  esac
fi
ARGS="$*"   # kept so 'check' can print the matching 'create' command
while [ $# -gt 0 ]; do
  case "$1" in
    --project)           PROJECT="$2"; shift 2 ;;
    --region)            REGION="$2"; shift 2 ;;
    --zones)             ZONES="$2"; shift 2 ;;
    --vm-count)          VM_COUNT="$2"; shift 2 ;;
    --machine-type)      MACHINE_TYPE="$2"; shift 2 ;;
    --ssd-count)         SSD_COUNT="$2"; shift 2 ;;
    --ssd-size)          SSD_SIZE="$2"; shift 2 ;;
    --ssd-interface)     SSD_INTERFACE="$2"; shift 2 ;;
    --prefix)            PREFIX="$2"; shift 2 ;;
    --retry-interval)    RETRY_INTERVAL="$2"; shift 2 ;;
    --max-attempts)      MAX_ATTEMPTS="$2"; shift 2 ;;
    --headroom-nodes)    HEADROOM_NODES="$2"; shift 2 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --simulate-stockout) SIMULATE_STOCKOUT="$2"; shift 2 ;;
    --yes|-y)            ASSUME_YES=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$PROJECT" ] || die "--project is required (see --help)"
need_int() { case "$2" in ''|*[!0-9]*) die "$1 must be a whole number, got '$2'" ;; esac; }
need_int --vm-count "$VM_COUNT"
need_int --ssd-count "$SSD_COUNT"
need_int --ssd-size "$SSD_SIZE"
need_int --retry-interval "$RETRY_INTERVAL"
need_int --max-attempts "$MAX_ATTEMPTS"
need_int --headroom-nodes "$HEADROOM_NODES"
need_int --simulate-stockout "$SIMULATE_STOCKOUT"
[ "$SIMULATE_STOCKOUT" -eq 0 ] || [ "$DRY_RUN" -eq 1 ] || die "--simulate-stockout only works with --dry-run"
case "$SSD_INTERFACE" in nvme|scsi) ;; *) die "--ssd-interface must be nvme or scsi" ;; esac

# Normalize zones: "a,b,c" -> "us-central1-a us-central1-b us-central1-c"
ZONE_LIST=""
for z in $(echo "$ZONES" | tr ',' ' '); do
  case "$z" in
    *-*) ZONE_LIST="$ZONE_LIST $z" ;;
    *)   ZONE_LIST="$ZONE_LIST $REGION-$z" ;;
  esac
done
ZONE_LIST="${ZONE_LIST# }"
NUM_ZONES=$(echo "$ZONE_LIST" | wc -w | tr -d ' ')

res_name() { echo "$PREFIX-${1##*-}"; }   # us-central1-c -> redpanda-tier5-c

# create_args prints one argument per line; create_cmd shows them as a command
# line; run_create runs them. All three read the same list, so they can't drift.
create_args() {
  printf '%s\n' compute reservations create "$(res_name "$1")" \
    "--project=$PROJECT" "--zone=$1" "--vm-count=$VM_COUNT" "--machine-type=$MACHINE_TYPE"
  # gcloud rejects --local-ssd=count=0, so a VM shape without local SSDs (for example one
  # that uses persistent disks) leaves the flag out.
  if [ "$SSD_COUNT" -gt 0 ]; then
    printf '%s\n' "--local-ssd=count=$SSD_COUNT,size=$SSD_SIZE,interface=$SSD_INTERFACE"
  fi
}
create_cmd() { echo "gcloud $(create_args "$1" | tr '\n' ' ' | sed 's/ $//')"; }
run_create() {
  local a args=()
  while IFS= read -r a; do args+=("$a"); done <<EOF
$(create_args "$1")
EOF
  gcloud "${args[@]}"
}

# Prints "count assuredCount inUseCount machineType ssdCount" for a reservation, or nothing.
describe_res() {
  local zone="$1" name
  name=$(res_name "$zone")
  gcloud compute reservations describe "$name" --project="$PROJECT" --zone="$zone" \
    --format="value(specificReservation.count,specificReservation.assuredCount,specificReservation.inUseCount,specificReservation.instanceProperties.machineType,specificReservation.instanceProperties.localSsds.len())" \
    2>/dev/null
}

print_spec() {
  echo "Reservation spec"
  echo "  project        $PROJECT"
  echo "  zones          $ZONE_LIST"
  if [ "$SSD_COUNT" -gt 0 ]; then
    echo "  per zone       $VM_COUNT x $MACHINE_TYPE, $SSD_COUNT x ${SSD_SIZE} GB local SSD ($SSD_INTERFACE)"
  else
    echo "  per zone       $VM_COUNT x $MACHINE_TYPE, no local SSD"
  fi
  echo "  total          $((VM_COUNT * NUM_ZONES)) VMs"
  echo "  consumption    automatic (any matching VM in the project can use it)"
  echo
}

# ---- check ------------------------------------------------------------------
preflight() {
  echo "Preflight checks"

  # gcloud present and new enough for --local-ssd=count=
  if ! command -v gcloud >/dev/null 2>&1; then
    fail "gcloud not found in PATH (https://cloud.google.com/sdk/docs/install)"
    return
  fi
  if [ "$SSD_COUNT" -eq 0 ]; then
    pass "no local SSDs requested ($(gcloud version 2>/dev/null | head -1))"
  elif gcloud compute reservations create --help 2>/dev/null | grep -q 'local-ssd=\[count=COUNT\]'; then
    pass "gcloud supports --local-ssd=count=… ($(gcloud version 2>/dev/null | head -1))"
  else
    fail "this gcloud doesn't support --local-ssd=count=…; run: gcloud components update"
  fi

  # credentials usable without a prompt, and the project is reachable
  local account err
  account=$(gcloud config get-value account 2>/dev/null)
  if err=$(gcloud projects describe "$PROJECT" --format='value(projectId)' 2>&1 >/dev/null); then
    pass "authenticated as ${account:-unknown account}; project $PROJECT is accessible"
  elif echo "$err" | grep -qiE 'reauth|refresh|credential|login'; then
    fail "gcloud CLI credentials for ${account:-the active account} are missing or expired; run: gcloud auth login"
    info "(gcloud auth application-default login is a different credential and does not fix this)"
    return
  else
    fail "cannot read project $PROJECT as ${account:-unknown account}: $(echo "$err" | grep -m1 ERROR)"
    return
  fi
  if gcloud services list --enabled --project="$PROJECT" --filter='config.name=compute.googleapis.com' \
       --format='value(config.name)' 2>/dev/null | grep -q compute; then
    pass "Compute Engine API is enabled"
  else
    fail "Compute Engine API is not enabled in $PROJECT"
  fi

  # IAM permissions needed by this script
  local perms want missing p
  want="compute.reservations.create compute.reservations.get compute.reservations.list compute.reservations.delete"
  perms=$(curl -sf -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" -H "Content-Type: application/json" \
    "https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT:testIamPermissions" \
    -d "{\"permissions\":[\"${want// /\",\"}\"]}" 2>/dev/null)
  if [ -z "$perms" ]; then
    warn "couldn't check IAM permissions (testIamPermissions call failed); continuing"
  else
    missing=""
    for p in $want; do
      echo "$perms" | grep -q "\"$p\"" || missing="$missing $p"
    done
    if [ -z "$missing" ]; then
      pass "you have the reservation permissions (create/get/list/delete)"
    else
      fail "missing IAM permissions:$missing (roles/compute.admin includes them)"
    fi
  fi

  # zones up and offering the machine type
  local zone status guest_cpus=""
  for zone in $ZONE_LIST; do
    status=$(gcloud compute zones describe "$zone" --project="$PROJECT" --format='value(status)' 2>/dev/null)
    if [ "$status" != "UP" ]; then
      fail "zone $zone: not found or not UP (status='${status:-none}')"
      continue
    fi
    local mt
    mt=$(gcloud compute machine-types describe "$MACHINE_TYPE" --zone="$zone" --project="$PROJECT" \
           --format='value(guestCpus)' 2>/dev/null)
    if [ -n "$mt" ]; then
      guest_cpus="$mt"
      pass "zone $zone is UP and offers $MACHINE_TYPE ($mt vCPUs)"
    else
      fail "zone $zone does not offer $MACHINE_TYPE"
    fi
  done
  info "a zone offering the machine type doesn't mean it has stock right now; only a create can tell"

  # regional quota: family CPUs + local SSD
  if [ -n "$guest_cpus" ]; then
    local family cpu_metric nodes per_ssd quotas
    family=$(echo "$MACHINE_TYPE" | cut -d- -f1 | tr '[:lower:]' '[:upper:]')
    cpu_metric="${family}_CPUS"
    nodes=$((VM_COUNT * NUM_ZONES))
    per_ssd=$((SSD_COUNT * SSD_SIZE))
    quotas=$(gcloud compute regions describe "$REGION" --project="$PROJECT" --flatten=quotas \
               --format='csv[no-heading](quotas.metric,quotas.limit,quotas.usage)' 2>/dev/null)
    # A reserved VM counts against quota once (a VM that consumes a reservation
    # doesn't count again), so the reservation needs quota for its own VMs.
    # Redpanda also needs HEADROOM_NODES nodes of spare quota for maintenance.
    check_quota() {
      local metric="$1" per_node="$2" unit="$3" line free need want
      need=$((per_node * nodes))
      want=$((per_node * (nodes + HEADROOM_NODES)))
      line=$(echo "$quotas" | grep "^$metric,")
      if [ -z "$line" ]; then
        warn "quota $metric not reported for $REGION; check it in the console"
        return
      fi
      free=$(echo "$line" | awk -F, '{printf "%d", $2 - $3}')
      if [ "$free" -lt "$need" ]; then
        fail "quota $metric: reservation needs $need $unit, only $free free; request an increase before creating"
      elif [ "$free" -lt "$want" ]; then
        warn "quota $metric: $free $unit free covers the reservation ($need) but not $HEADROOM_NODES nodes of headroom ($want); request an increase before the cluster change"
      else
        pass "quota $metric: need $want $unit including $HEADROOM_NODES nodes of headroom, $free free ($(echo "$line" | awk -F, '{printf "limit %d, used %d", $2, $3}'))"
      fi
    }
    check_quota "$cpu_metric" "$guest_cpus" "vCPUs"
    if [ "$SSD_COUNT" -gt 0 ]; then
      check_quota "LOCAL_SSD_TOTAL_GB" "$per_ssd" "GB"
    fi
  fi

  # existing reservations
  local existing
  for zone in $ZONE_LIST; do
    existing=$(describe_res "$zone")
    if [ -n "$existing" ]; then
      warn "reservation $(res_name "$zone") already exists in $zone (count/assured/inUse: $(echo "$existing" | awk '{print $1"/"$2"/"$3}')); create will skip it"
    fi
  done
  existing=$(gcloud compute reservations list --project="$PROJECT" \
               --filter="specificReservation.instanceProperties.machineType=$MACHINE_TYPE" \
               --format='value(name,zone.basename())' 2>/dev/null | grep -v "^$PREFIX-" || true)
  if [ -n "$existing" ]; then
    warn "other $MACHINE_TYPE reservations already exist in $PROJECT: $(echo "$existing" | tr '\t\n' ' ,')"
  else
    pass "no conflicting $MACHINE_TYPE reservations in $PROJECT"
  fi
  echo
}

cmd_check() {
  print_spec
  preflight
  echo "Commands 'create' will run (nothing has been created):"
  local zone
  for zone in $ZONE_LIST; do echo "  $(create_cmd "$zone")"; done
  echo
  if [ "$FAILS" -gt 0 ]; then
    echo "${C_RED}$FAILS check(s) failed${C_OFF}, $WARNS warning(s). Fix the failures before running create."
    exit 1
  fi
  echo "${C_GRN}All checks passed${C_OFF} ($WARNS warning(s)). Next: $0 create $ARGS"
}

# ---- create -----------------------------------------------------------------
# Returns 0 created, 2 out of stock (retry), 1 other error.
try_create() {
  local zone="$1" attempt="$2" out
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    [dry-run] $(create_cmd "$zone")"
    if [ "$attempt" -le "$SIMULATE_STOCKOUT" ]; then
      echo "    [dry-run] simulated: ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS"
      return 2
    fi
    return 0
  fi
  out=$(run_create "$zone" 2>&1)
  local rc=$?
  [ $rc -eq 0 ] && return 0
  if echo "$out" | grep -qiE 'RESOURCE_POOL_EXHAUSTED|STOCKOUT|does not have enough resources|currently unavailable'; then
    echo "    out of stock: $(echo "$out" | grep -m1 -iE 'code:|message:' | sed 's/^ *//')"
    return 2
  fi
  printf '%s\n' "$out" | sed 's/^/    /'
  if echo "$out" | grep -q 'RESERVATION_CAPACITY_LIMIT_EXCEEDED'; then
    echo "    hint: GCP refuses a new reservation in a zone where matching VMs already run and it"
    echo "          has no spare reservation capacity for the machine family. Reserve before the VMs"
    echo "          exist (before the cluster is created or the tier changes), or use another zone."
  fi
  return 1
}

cmd_create() {
  print_spec
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "${C_YLW}DRY RUN${C_OFF}: nothing will be created."
  else
    echo "${C_YLW}Billing starts as soon as each reservation is created.${C_OFF}"
  fi
  echo
  preflight
  if [ "$FAILS" -gt 0 ]; then
    echo "${C_RED}$FAILS preflight check(s) failed${C_OFF}; not creating anything."
    exit 1
  fi

  local pending="" zone
  for zone in $ZONE_LIST; do
    if [ "$DRY_RUN" -eq 0 ] && [ -n "$(describe_res "$zone")" ]; then
      echo "$(ts)  $zone: $(res_name "$zone") already exists, skipping"
    else
      pending="$pending $zone"
    fi
  done

  # Attempt counters per zone, kept as "zone=N" words (bash 3.2 has no assoc arrays).
  local attempts="" pass_no=0 next n rc
  get_attempts() { echo "$attempts" | tr ' ' '\n' | grep "^$1=" | cut -d= -f2; }
  set_attempts() { attempts="$(echo "$attempts" | tr ' ' '\n' | grep -v "^$1=" | tr '\n' ' ') $1=$2"; }

  while [ -n "$(echo "$pending" | tr -d ' ')" ]; do
    pass_no=$((pass_no + 1))
    next=""
    for zone in $pending; do
      n=$(( $(get_attempts "$zone" || echo 0) + 1 ))
      set_attempts "$zone" "$n"
      echo "$(ts)  $zone: attempt $n"
      try_create "$zone" "$n"; rc=$?
      case $rc in
        0) echo "$(ts)  $zone: ${C_GRN}reserved${C_OFF} $(res_name "$zone")" ;;
        2) if [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$n" -ge "$MAX_ATTEMPTS" ]; then
             echo "$(ts)  $zone: ${C_RED}giving up${C_OFF} after $n attempts"
           else
             next="$next $zone"
           fi ;;
        *) echo "$(ts)  $zone: ${C_RED}failed${C_OFF} with a non-stockout error; not retrying"
           echo "Fix the error above and run create again. Zones already reserved are kept (and billed)."
           exit 1 ;;
      esac
    done
    pending="$next"
    if [ -n "$(echo "$pending" | tr -d ' ')" ]; then
      echo "$(ts)  still out of stock:$pending; retrying in ${RETRY_INTERVAL}s (Ctrl-C to stop; reserved zones stay reserved)"
      sleep "$RETRY_INTERVAL"
    fi
  done
  echo
  [ "$DRY_RUN" -eq 1 ] && { echo "Dry run complete. Nothing was created."; exit 0; }
  cmd_status
}

# ---- status / delete --------------------------------------------------------
cmd_status() {
  echo "Reservations in $PROJECT (want count=$VM_COUNT and assured=$VM_COUNT in every zone; inUse fills in as nodes come up):"
  printf '  %-22s %-16s %6s %8s %6s\n' NAME ZONE COUNT ASSURED INUSE
  local zone line count assured inuse all_ok=1
  for zone in $ZONE_LIST; do
    line=$(describe_res "$zone")
    if [ -z "$line" ]; then
      printf '  %-22s %-16s %s\n' "$(res_name "$zone")" "$zone" "(not created)"
      all_ok=0
      continue
    fi
    read -r count assured inuse _ <<EOF
$line
EOF
    printf '  %-22s %-16s %6s %8s %6s\n' "$(res_name "$zone")" "$zone" "$count" "${assured:-0}" "${inuse:-0}"
    [ "${assured:-0}" = "$VM_COUNT" ] || all_ok=0
  done
  echo
  if [ "$all_ok" -eq 1 ]; then
    echo "${C_GRN}All zones hold $VM_COUNT VMs.${C_OFF} Capacity is held; go ahead with the tier change or cluster creation."
  else
    echo "${C_YLW}Not every zone holds its VMs yet.${C_OFF}"
  fi
}

cmd_delete() {
  echo "This deletes these reservations in $PROJECT (running VMs keep running):"
  local zone
  for zone in $ZONE_LIST; do echo "  $(res_name "$zone")  ($zone)"; done
  if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'Type "delete" to continue: '
    read -r answer
    [ "$answer" = "delete" ] || die "aborted"
  fi
  for zone in $ZONE_LIST; do
    if [ -z "$(describe_res "$zone")" ]; then
      echo "  $(res_name "$zone"): not found, skipping"
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  [dry-run] gcloud compute reservations delete $(res_name "$zone") --project=$PROJECT --zone=$zone --quiet"
    else
      gcloud compute reservations delete "$(res_name "$zone")" --project="$PROJECT" --zone="$zone" --quiet
    fi
  done
}

case "$CMD" in
  check)  cmd_check ;;
  create) cmd_create ;;
  status) cmd_status ;;
  delete) cmd_delete ;;
esac
