# F5 BIG-IP Next for Kubernetes 2.3 — Terraform Wrapper

This project is a thin Terraform root module that wraps the existing per-phase
sub-modules and drives a complete F5 BIG-IP Next for Kubernetes 2.3 deployment
on IBM Cloud with the standard `terraform init / plan / apply / destroy`
workflow.

## What this project does

Each deployment phase has its own self-contained module under `modules/`:

| Phase | Module | Purpose |
|------:|--------|---------|
| 1 | `roks_cluster`  | ROKS (OpenShift) cluster, VPC, Transit Gateway, registry COS instance |
| 2 | `cert_manager`  | cert-manager Helm install on the cluster |
| 3 | `flo`           | F5 Lifecycle Operator (FLO) and supporting resources |
| 4 | `cne_instance`  | CNEInstance custom resource |
| 5 | `license`       | License custom resource |
| 6 | `testing`       | Optional jumphost infrastructure for validation |

Phases 3–5 are gated by the top-level `deploy_bnk` flag (default `true`).
Set `deploy_bnk = false` in `terraform.tfvars` to provision only the cluster
and cert-manager — useful for staging the prerequisites separately from the
BIG-IP Next workload.

The root module (`main.tf`) instantiates each sub-module once and wires
outputs of earlier phases into the inputs of later phases. The Terraform
dependency graph then enforces the correct execution order automatically:

```
roks_cluster ──► cert_manager ──► flo ──► cne_instance ──► license
            └──────────────────────────────────────────► testing
```

There is no orchestration script, no per-phase workspace, and no state
hand-off between phases. Running a single `terraform apply` from the root
walks the graph and applies the phases in order. `terraform destroy` walks
it in reverse.

## State

State is held in **standard Terraform state files** at the root of this
project (`terraform.tfstate` / `terraform.tfstate.backup` by default).
Every resource across every phase lives in this single state file.

Switch to a remote backend (IBM Cloud Object Storage, Terraform Cloud, S3,
etc.) by adding a `backend` block to `versions.tf` if you want shared or
durable state — nothing in the wrapper depends on local state.

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — at minimum set ibmcloud_api_key
terraform init
terraform plan
terraform apply
# ... when finished:
terraform destroy
```

See `terraform.tfvars.example` for the full set of inputs and their defaults.
The only variable without a default is `ibmcloud_api_key`.

Common toggles in `terraform.tfvars`:

| Variable                     | Default | Effect when `false` |
|------------------------------|:-------:|---------------------|
| `create_roks_cluster`         | `true`  | Use an existing cluster (`roks_cluster_id_or_name`) instead of creating one |
| `create_roks_transit_gateway` | `true`  | Reuse an existing Transit Gateway (`roks_transit_gateway_name`) |
| `install_cert_manager`        | `true`  | Skip the cert-manager Helm install (FLO uses an already-installed one) |
| `deploy_bnk`                  | `true`  | Skip phases 3–5 (FLO, CNEInstance, License) — cluster + cert-manager only |

## deploy.sh

`deploy.sh` is a small convenience wrapper around `terraform apply` that
picks interactive vs. non-interactive mode based on whether stdin is a
terminal:

- **Interactive** (run from a shell): prompts for approval before applying.
- **Non-interactive** (piped, redirected, or run from CI): applies with
  `-auto-approve`.

```bash
# Interactive — Terraform shows the plan and waits for "yes"
./deploy.sh

# Non-interactive — auto-approve (CI, cron, nohup, etc.)
./deploy.sh < /dev/null
nohup ./deploy.sh > deploy.log 2>&1 &
```

Use plain `terraform` commands directly when you want fine-grained control
(for example `terraform plan -out`, `-target`, or `-replace`); use
`deploy.sh` for the common case of "apply everything from `terraform.tfvars`."

## run_tests.sh

`run_tests.sh` is an end-to-end test driver that exercises the wrapper
through `init → plan → apply → destroy` against four real IBM Cloud
deployment scenarios and reports PASS / FAIL per phase.

The four scenarios cover the common combinations of "create" vs.
"reuse existing" for cluster, Transit Gateway, and cert-manager:

| # | Scenario | `create_roks_cluster` | `create_roks_transit_gateway` | `install_cert_manager` |
|---|----------|:---------------------:|:-----------------------------:|:----------------------:|
| 1 | `full` | true  | true  | true  |
| 2 | `existing-cluster-create-tgw` | false | true  | true  |
| 3 | `existing-cluster-existing-tgw` | false | false | true  |
| 4 | `existing-cluster-create-tgw-existing-cert-manager` | false | true  | false |

Each scenario runs from the project root but uses an **isolated
`.terraform` directory and state file** under `test-runs/<timestamp>/`,
so the project's own state is never touched and scenarios can't collide
with each other. Resource names get a per-run, per-scenario suffix
(`-tN-HHMM`) so back-to-back runs don't conflict in IBM Cloud.

Scenarios 2–4 all need a pre-existing cluster / TGW / cert-manager, so
the script provisions a **shared prereqs workspace** once before they
start (cluster + TGW + cert-manager, with `deploy_bnk=false`) and tears
it down after all three finish. Scenario 1 runs independently.

Logs and per-scenario tfvars are written under
`test-runs/<UTC-timestamp>/`:

```
test-runs/20260504_065205/
├── summary.log
├── prereqs/                 # shared cluster/TGW/cert-manager (scenarios 2–4)
├── scenario-1-full/
│   ├── terraform_full.tfvars
│   ├── terraform.tfstate
│   ├── phase-init.log
│   ├── phase-plan.log
│   ├── phase-apply.log
│   └── phase-destroy.log
├── scenario-2-existing-cluster-create-tgw/
└── ...
```

### Usage

```bash
# All four scenarios, with destroy after each
./run_tests.sh

# Subset — by number or by label
./run_tests.sh 1 3
./run_tests.sh full existing-cluster-existing-tgw

# Leave resources up after apply (useful for debugging a failure)
./run_tests.sh --no-destroy 1

# Pick a custom output directory
./run_tests.sh --run-dir /tmp/bnk-test-2026-05-04 1

# Recover after a crash / SIGKILL — destroy any state still on disk
./run_tests.sh --cleanup test-runs/20260504_065205
```

### Safety

The script registers each `apply` for cleanup and installs an `EXIT`
trap, so Ctrl-C, a `set -e` bailout, or `SIGTERM` triggers an
**emergency destroy** of every active state file before the script
exits. If the script itself is killed (`SIGKILL`, host crash, etc.)
the `--cleanup DIR` mode walks a prior run directory and destroys any
non-empty state files it finds.

The base `terraform.tfvars` at the project root is the input template —
the script generates a per-scenario tfvars file from it with the
necessary overrides applied; it never modifies the original.

## Layout

```
.
├── main.tf                  # instantiates and wires the phase modules
├── variables.tf             # root inputs (forwarded to the modules)
├── outputs.tf               # root outputs (surfaced from the modules)
├── providers.tf             # ibm / null / http providers
├── versions.tf              # required Terraform and provider versions
├── deploy.sh                # interactive / non-interactive apply wrapper
├── run_tests.sh             # 4-scenario init/plan/apply/destroy test suite
├── Dockerfile               # builds the runner image
├── docker-entrypoint.sh     # symlink-farm setup for the /work volume
├── .dockerignore            # excludes state, secrets, and caches from the build
├── terraform.tfvars.example # template for your terraform.tfvars
└── modules/
    ├── roks_cluster/
    ├── cert_manager/
    ├── flo/
    ├── cne_instance/
    ├── license/
    └── testing/
```

## Running in Docker

A `Dockerfile` is provided that builds a self-contained Alpine image with
Terraform, all required providers, the project source, and the helper
CLIs the modules shell out to (`kubectl`, `helm`, `curl`, `tar`,
`python3`).  `terraform init` runs during the build, so the image ships
with `.terraform.lock.hcl` and every provider already cached — no
registry access is needed at runtime.

### Build

```bash
docker build -t bnk-terraform .
# Pin a different Terraform version if you like:
docker build --build-arg TERRAFORM_VERSION=1.9.8 -t bnk-terraform .
```

### State persistence

The image's WORKDIR is `/work`, declared as a Docker `VOLUME`.  Mount a
named volume (or a host directory) there and **all** mutable Terraform
output is kept across runs:

| Path inside `/work`                         | Contents                                  |
|---------------------------------------------|-------------------------------------------|
| `terraform.tfstate` / `terraform.tfstate.backup` | root-module state from `terraform apply` / `deploy.sh` |
| `test-runs/<timestamp>/`                    | every `run_tests.sh` invocation's logs and per-scenario state |
| `terraform.tfvars` (if you put it there)    | your inputs — survives across containers  |

The entrypoint populates `/work` on first use with symlinks back into
the baked-in project tree at `/opt/tf-project`, so terraform finds the
`.tf` files, modules, and provider cache without copying anything.
Image upgrades are picked up automatically — relinked on every run.

Create the volume once:

```bash
docker volume create bnk-state
```

### Provide credentials and inputs

Bind-mount your `terraform.tfvars` over the one in the volume (it
contains the IBM Cloud API key, so keep it on the host):

```bash
-v "$(pwd)/terraform.tfvars:/work/terraform.tfvars:ro"
```

Or pass individual inputs via `TF_VAR_*` environment variables:

```bash
-e TF_VAR_ibmcloud_api_key=$IBMCLOUD_API_KEY
```

### Common commands — `docker run -it`

All examples assume `bnk-state` is your volume and `terraform.tfvars`
sits in the current directory on the host.  `--rm` removes the
container on exit; the volume (and its state) survives.

```bash
# terraform init — already done during build, but safe to re-run
docker run -it --rm \
  -v bnk-state:/work \
  -v "$(pwd)/terraform.tfvars:/work/terraform.tfvars:ro" \
  bnk-terraform terraform init

# terraform plan
docker run -it --rm \
  -v bnk-state:/work \
  -v "$(pwd)/terraform.tfvars:/work/terraform.tfvars:ro" \
  bnk-terraform terraform plan -var-file terraform.tfvars

# terraform apply (interactive — prompts for "yes")
docker run -it --rm \
  -v bnk-state:/work \
  -v "$(pwd)/terraform.tfvars:/work/terraform.tfvars:ro" \
  bnk-terraform terraform apply -var-file terraform.tfvars

# terraform destroy
docker run -it --rm \
  -v bnk-state:/work \
  -v "$(pwd)/terraform.tfvars:/work/terraform.tfvars:ro" \
  bnk-terraform terraform destroy -var-file terraform.tfvars
```

`deploy.sh` works the same way; pass it as the command instead of
`terraform`:

```bash
# Interactive apply via deploy.sh
docker run -it --rm \
  -v bnk-state:/work \
  -v "$(pwd)/terraform.tfvars:/work/terraform.tfvars:ro" \
  bnk-terraform ./deploy.sh

# Non-interactive (auto-approve) — drop -t and feed /dev/null on stdin
docker run -i --rm \
  -v bnk-state:/work \
  -v "$(pwd)/terraform.tfvars:/work/terraform.tfvars:ro" \
  bnk-terraform ./deploy.sh < /dev/null
```

`run_tests.sh` lands its `test-runs/<timestamp>/` tree in the same
volume, so logs and per-scenario state persist for inspection or
recovery via `--cleanup`:

```bash
# Full 4-scenario test suite
docker run -it --rm \
  -v bnk-state:/work \
  -v "$(pwd)/terraform.tfvars:/work/terraform.tfvars:ro" \
  bnk-terraform ./run_tests.sh

# A single scenario, leaving resources up
docker run -it --rm \
  -v bnk-state:/work \
  -v "$(pwd)/terraform.tfvars:/work/terraform.tfvars:ro" \
  bnk-terraform ./run_tests.sh --no-destroy 1

# Recover after a crash — destroy any state still in the volume
docker run -it --rm \
  -v bnk-state:/work \
  -v "$(pwd)/terraform.tfvars:/work/terraform.tfvars:ro" \
  bnk-terraform ./run_tests.sh --cleanup test-runs/20260504_065205
```

For ad-hoc poking around — copying the example tfvars, viewing logs,
re-running pieces by hand — drop into a shell:

```bash
docker run -it --rm \
  -v bnk-state:/work \
  -v "$(pwd)/terraform.tfvars:/work/terraform.tfvars:ro" \
  bnk-terraform bash
```

Inside the container `/work` is your CWD, every project file is
available (via symlinks to `/opt/tf-project`), and any state, logs,
or test-runs you produce stay in `bnk-state`.

## Requirements

- Terraform >= 1.5
- IBM Cloud API key with permissions for VPC, ROKS, Transit Gateway, COS,
  and IAM trusted profiles in the target resource group
- Access to the F5 FAR repository and the COS bucket holding the FAR auth
  key and subscription JWT (see the `flo` / `license` sections in
  `terraform.tfvars.example`)
