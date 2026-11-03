# redpanda-gcp-reserve

This script reserves Compute Engine capacity in your GCP project before a [Redpanda BYOC](https://docs.redpanda.com/cloud-data-platform/get-started/cluster-types/byoc/) cluster needs it. Use it for a tier change, a new cluster, or any other operation that brings up new nodes. When a GCP zone is out of stock for a machine type (`ZONE_RESOURCE_POOL_EXHAUSTED`), those operations stall until capacity frees up. A reservation holds the capacity for you in advance. The script keeps retrying zones that are out of stock until every zone holds its share.

The script only needs `gcloud`. It runs on Linux and on macOS with the bash 3.2 that ships there.

> This is a community tool and not an official Redpanda product. Before you reserve anything, confirm the node shape for your tier with your Redpanda account team.

## How it works

Redpanda's GKE node pools don't set a reservation affinity, so they use any reservation in the project that matches automatically. The match has to be exact on:

- zone
- machine type
- the number, size and interface of local SSDs

A reservation that doesn't match won't be used and still bills. The script creates one reservation per zone, named `<prefix>-<zone suffix>`, with automatic consumption. It never sets `--require-specific-reservation` or a minimum CPU platform, since either one would stop the node pools from matching.

**Billing:** GCP bills a reservation as running VMs from the moment it exists, whether or not anything is using it. Create reservations right before you need the nodes, and delete any you no longer need. Once the cluster's nodes are using a reservation, you pay nothing extra for it, and it keeps the capacity held if a node gets replaced.

## Prerequisites

- `gcloud`, recent enough to support `--local-ssd=count=` (run `gcloud components update` if not)
- CLI credentials: `gcloud auth login`. Application default credentials (`gcloud auth application-default login`) are a separate credential and won't work.
- `roles/compute.admin` on the project, or at least `compute.reservations.create/get/list/delete`
- Regional quota for the reserved VMs. Redpanda also asks for [3 nodes of headroom](https://docs.redpanda.com/cloud-data-platform/get-started/cluster-types/byoc/gcp/vpc-byo-gcp/#gcp-quotas) on top, for maintenance.

## Usage

```bash
curl -fsSLO https://raw.githubusercontent.com/vuldin/redpanda-gcp-reserve/main/redpanda-gcp-reserve.sh
chmod +x redpanda-gcp-reserve.sh
```

**1. Preflight.** This step is read-only. It checks your credentials and permissions, confirms that each zone offers the machine type, and checks quota for the reservation plus headroom. Then it prints the exact `gcloud` commands that `create` will run.

```bash
./redpanda-gcp-reserve.sh check --project my-project --region us-east4 --zones a,b,c
```

**2. (Optional) Dry run.** This walks through the create flow without creating anything. `--simulate-stockout 2` fakes two stockouts per zone so you can watch the retry loop.

```bash
./redpanda-gcp-reserve.sh create --project my-project --dry-run --simulate-stockout 2 --retry-interval 5
```

**3. Create.** Zones that are out of stock are retried every `--retry-interval` seconds. Zones that succeed stay reserved while the others retry. `--max-attempts 0` keeps trying until you stop it. You can press Ctrl-C and re-run at any time, because existing reservations are skipped.

```bash
./redpanda-gcp-reserve.sh create --project my-project --region us-east4 --zones a,b,c --max-attempts 0
```

**4. Status.** When every zone shows `COUNT` and `ASSURED` equal to `--vm-count`, the capacity is held and you can go ahead with the tier change or cluster creation. `INUSE` goes up as nodes come up.

```bash
./redpanda-gcp-reserve.sh status --project my-project --region us-east4 --zones a,b,c
```

**5. Delete** reservations you no longer need, for example after downgrading. Running VMs keep running.

```bash
./redpanda-gcp-reserve.sh delete --project my-project --region us-east4 --zones a,b,c
```

Pass the same `--region`, `--zones` and `--prefix` to every subcommand, because those flags determine which reservations it manages.

## Options

| Flag | Default | Description |
|---|---|---|
| `--project ID` | (required) | GCP project where the cluster's nodes run. For BYOVPC with a shared VPC, this is the service project. |
| `--region REGION` | `us-central1` | Region |
| `--zones LIST` | `a,b,c` | Comma-separated zone suffixes (`a,b,c`) or full names (`us-east4-a`) |
| `--vm-count N` | `2` | VMs to reserve per zone |
| `--machine-type TYPE` | `n2d-standard-16` | Machine type of the tier's nodes |
| `--ssd-count N` | `16` | Local SSDs per VM |
| `--ssd-size GB` | `375` | Size of each local SSD |
| `--ssd-interface IF` | `nvme` | `nvme` or `scsi` |
| `--prefix NAME` | `redpanda-tier5` | Reservation names are `<prefix>-<zone suffix>` |
| `--retry-interval SEC` | `60` | Wait between passes over zones that are out of stock |
| `--max-attempts N` | `120` | Attempts per zone before giving up. `0` means retry forever. |
| `--headroom-nodes N` | `3` | Extra nodes of quota to check for. Warns if quota covers the reservation but not the headroom. |
| `--dry-run` | | `create`/`delete`: print the commands instead of running them |
| `--simulate-stockout N` | `0` | With `--dry-run`: fail each zone's first N attempts with a fake stockout |
| `--yes` | | `delete`: skip the confirmation prompt |

## Tier shapes

The defaults match BYOC tier 5 on GCP (`tier-5-gcp-v2-x86`), which is 6 x `n2d-standard-16`, each with 16 x 375 GB NVMe local SSD, 2 per zone across 3 zones. For any other tier, ask Redpanda for the exact node shape and set `--vm-count`, `--machine-type`, `--ssd-count` and `--ssd-size` to match. Give each tier its own `--prefix` so its reservations are easy to tell apart:

```bash
./redpanda-gcp-reserve.sh check --project my-project \
  --vm-count 4 --machine-type n2d-standard-4 --ssd-count 4 --prefix redpanda-tier4
```

The vCPU quota check derives the quota family from the machine type, so `n2d-*` checks `N2D_CPUS`.

## Exit codes

- `0`: success. For `check`, there may still be warnings.
- `1`: a failed check, a bad argument, or a non-stockout error from GCP. `create` stops on errors that aren't stockouts. Zones that were already reserved are kept, and they bill.

## Tests

`tests/run.sh` runs the script against stub `gcloud` and `curl` commands in `tests/stubs`, so it never touches GCP. The tests cover argument validation, the preflight checks, the dry run, and the real create path, including retries, giving up, and errors that aren't stockouts. They also cover status and delete.

```bash
tests/run.sh
shellcheck redpanda-gcp-reserve.sh tests/run.sh tests/stubs/*
```

CI runs both on Linux and on macOS, where the tests run under bash 3.2.

## License

MIT
