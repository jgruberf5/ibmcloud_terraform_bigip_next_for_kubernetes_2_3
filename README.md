# F5 BIG-IP Next for Kubernetes 2.3 — Terraform Wrapper

A Terraform root module that drives a complete F5 BIG-IP Next for Kubernetes
2.3 deployment on IBM Cloud — VPC, ROKS (OpenShift) cluster, Transit
Gateway, cert-manager, the F5 Lifecycle Operator (FLO), CNEInstance, and
license — through a single `terraform apply`.

The repo ships a docker-based runner image with every CLI baked in
(`terraform`, `ibmcloud`, `kubectl`, `oc`, `helm`, `jq`) and a single
front-end command, **`bnk`**, that wraps the docker plumbing so you never
have to type `docker run -it --rm -v …` yourself.

---

## Install

<!-- BNK_INSTALL_URL_BEGIN -->
```bash
curl -fsSL https://raw.githubusercontent.com/jgruberf5/ibmcloud_terraform_bigip_next_for_kubernetes_2_3/v0.6.4/install.sh | bash
```
<!-- BNK_INSTALL_URL_END -->

The installer:

1. Verifies host dependencies (`bash 3.2+`, `docker` + reachable daemon, `curl`, `awk`, `tr`, `date`, basic coreutils) and refuses to install if any are missing.
2. Resolves the latest release tag from the GitHub API (or use `BNK_VERSION=v2.3.0` to pin).
3. Downloads `bnk` to `~/.local/bin` (override with `INSTALL_DIR=…`).
4. Warns if that directory isn't on your `PATH`.

Verify and pull the runner image lazily on first use — `bnk doctor` reports any environment problems, then `bnk plan` / `bnk apply` will `docker pull` the image automatically the first time they need it.

**Air-gapped install** (you already have the runner image but no internet from the host):

```bash
docker run --rm -v "$HOME/.local/bin:/dest" \
    ghcr.io/jgruberf5/ibmcloud-terraform-bnk-2-3:latest \
    bnk install
```

This copies bnk out of the image to `/dest/bnk`. Same end state as the curl install.

**Uninstall:**

```bash
rm ~/.local/bin/bnk
# Optionally also remove the runner image:
docker image rm ghcr.io/jgruberf5/ibmcloud-terraform-bnk-2-3
```

Per-project state lives in each project's directory — to wipe a
project, `cd` into it and run `bnk delete`.

---

## Quickstart

```bash
bnk init                                     # interactive tfvars wizard
bnk plan                                     # plan with module-grouped summary
bnk apply                                    # apply (interactive)
bnk shell                                    # auth'd kubectl/oc/ibmcloud shell
bnk destroy                                  # tear it all down
```

If anything looks off:

```bash
bnk doctor      # check docker, image, tfvars, IBM Cloud auth
bnk status      # one-screen view of tfstate + cluster + workloads
```

---

## The `bnk` CLI

`bnk` is the single entry point for everything in this repo. It wraps the
docker runner image, exposes a kubectl-style verb-noun surface, and ships
tab completion.

### Top-level surface

| Command                       | What it does |
|-------------------------------|--------------|
| `bnk init`                    | Interactive tfvars wizard — prompts for the must-set values, validates the API key against IBM Cloud, writes `terraform.tfvars` |
| `bnk doctor`                  | Preflight checks: docker, image, volume, tfvars, IBM Cloud auth |
| `bnk status [--drift]`        | One-screen dashboard: account, terraform state freshness, cluster health, workload pod counts. `--drift` adds a `terraform plan -refresh-only` check (slow) |
| `bnk plan`                    | `terraform plan` plus a module-grouped change summary (`+add ~chg -del ±rep`) |
| `bnk apply [--auto]`          | `terraform apply` (interactive); `--auto` adds `-auto-approve` for CI |
| `bnk destroy`                 | `terraform destroy` |
| `bnk delete [--force]`        | `rm -rf .bnk` after a typed confirmation. Refuses if tfstate has provisioned resources (`--force` overrides) — keeps you from orphaning a live cluster |
| `bnk teardown`                | `bnk destroy` + `bnk delete` in one command, single confirmation |
| `bnk shell`                   | Interactive shell with kubeconfig + ibmcloud session in place |
| `bnk kubectl …` / `oc …` / `ibmcloud …` | One-shot cluster commands |
| `bnk completion <bash\|zsh>`  | Print completion script — `source <(./bnk completion bash)` |

### Subgroups

```
bnk infra    init | plan | apply | destroy | delete | output | test
bnk cluster  shell | kubectl | oc | ibmcloud | info
bnk exec     <cmd...>     # arbitrary command inside the container
```

`bnk plan`, `bnk apply`, `bnk shell`, `bnk kubectl …` are short aliases
for the equivalent group form. Every infra subcommand requires
`terraform.tfvars` in the current directory.

### `bnk doctor`

Tiered preflight; prints `✓` / `✗` / `!` per check with remediation hints:

1. **Host** — docker present, daemon reachable, image age, cwd writable
2. **Project** — tfvars present, `ibmcloud_api_key` not a placeholder, region set
3. **Container probes** (one `docker run`) — live `ibmcloud login` against the configured region, `terraform validate`

Skipped checks degrade gracefully: a failed host check skips container
probes so the user sees the real problem first.

### `bnk status`

```
IBM Cloud
  region          ca-tor
  account         12345abcde

Terraform
  state           67 resources, 2h since last write
  drift           none                              # only with --drift

Cluster  tf-openshift-cluster
  state           normal
  masters         Ready
  version         4.18.21_1551
  workers         3 Ready
  nodes           3/3 Ready

Workloads
  f5-bnk          12/12
  f5-utils         4/4
  cert-manager     3/3
```

Auth happens once at the top, so the IBM Cloud, cluster, and kubectl
calls share a single 50-minute cached login. If cluster auth fails
(e.g. pre-apply), the IBM Cloud and Terraform sections still render.

### `bnk plan` summary

After the normal terraform plan output, bnk appends a module-grouped
table by parsing the saved plan:

```
── plan summary ──────────────────────────────────────
  module                                    +add ~chg -del ±rep
  <root>                                       1    0    0    0
  module.openshift                             4    1    0    0
  module.bnk                                   1    1    0    1
  module.networking                            0    0    1    0
  TOTAL                                        6    2    1    1
```

`±rep` (replacements) is tracked separately from add/del — terraform's own
summary line counts them as both, which is misleading. `data` reads are
ignored.

### `bnk delete` and `bnk teardown`

`bnk delete` is `rm -rf .bnk` after a typed `delete` confirmation —
wipes terraform state, kubeconfig, ibmcloud session, plan files, and
per-run test state in one stroke. `terraform.tfvars` is left alone.

**Guard rail:** if `terraform.tfstate` lists provisioned resources,
`bnk delete` refuses and points at `bnk destroy` first. This keeps
you from orphaning a live cluster (it would keep billing, and you'd
lose the ability to manage it from here). Pass `--force` to skip the
guard if you really mean "drop local state, leave the cloud alone".

`bnk teardown` is the convenience: one typed confirmation, then
`terraform destroy -auto-approve` followed by `rm -rf .bnk`. If the
destroy fails partway through, `.bnk/` is preserved so you can
inspect logs and retry.

| Goal                                              | Command       |
|---------------------------------------------------|---------------|
| Tear down the cloud, keep state for re-apply      | `bnk destroy` |
| Drop local state (only if no resources)           | `bnk delete`  |
| Drop local state regardless                       | `bnk delete --force` |
| Tear down the cloud and drop state in one go      | `bnk teardown` |

### Tab completion

```bash
source <(./bnk completion bash)        # one-off
./bnk completion bash >> ~/.bash_completion   # persist

source <(./bnk completion zsh)         # one-off (zsh)
```

Completes top-level commands, `infra`/`cluster` subcommands, and
`completion bash|zsh`.

### Environment overrides

| Variable | Default                          | Effect |
|----------|----------------------------------|--------|
| `IMAGE`  | `ghcr.io/jgruberf5/ibmcloud-terraform-bnk-2-3:latest` | Image bnk runs (override to use a local build or a different tag) |

---

## What this project deploys

Each phase has its own self-contained module under `modules/`:

| Phase | Module          | Purpose |
|------:|-----------------|---------|
| 1     | `roks_cluster`  | VPC, ROKS (OpenShift) cluster, Transit Gateway, registry COS instance |
| 2     | `cert_manager`  | cert-manager Helm install on the cluster |
| 3     | `flo`           | F5 Lifecycle Operator (FLO) and supporting resources |
| 4     | `cne_instance`  | CNEInstance custom resource |
| 5     | `license`       | License custom resource |
| 6     | `testing`       | Optional jumphost infrastructure for validation |

Phases 3–5 are gated by the top-level `deploy_bnk` flag (default `true`).
Set `deploy_bnk = false` in `terraform.tfvars` to provision only the
cluster and cert-manager.

The root module (`main.tf`) instantiates each sub-module once and wires
outputs of earlier phases into the inputs of later phases. Terraform's
dependency graph then enforces the correct execution order:

```
roks_cluster ──► cert_manager ──► flo ──► cne_instance ──► license
            └──────────────────────────────────────────► testing
```

A single `bnk apply` walks the graph forward; `bnk destroy` walks it in
reverse. There is no per-phase orchestration script and no state
hand-off between phases.

---

## Configuration

`terraform.tfvars` holds the inputs. Generate a starter file with
`bnk init`, or copy `terraform.tfvars.example` and edit by hand. The only
input without a default is `ibmcloud_api_key`.

### Most common toggles

| Variable                       | Default | Effect when `false` |
|--------------------------------|:-------:|---------------------|
| `create_roks_cluster`          | `true`  | Use an existing cluster (set `roks_cluster_id_or_name`) |
| `create_roks_transit_gateway`  | `true`  | Reuse an existing Transit Gateway (set `roks_transit_gateway_name`) |
| `install_cert_manager`         | `true`  | Skip the cert-manager Helm install |
| `deploy_bnk`                   | `true`  | Skip phases 3–5 — cluster + cert-manager only |

See `terraform.tfvars.example` for the full list and inline comments.

---

## Docker runner image

The runner image is published — `bnk` pulls it on first use and you do
not normally need to build it yourself. It's an Alpine image containing
every CLI the modules shell out to: `terraform`, `ibmcloud` (with the
`container-service` and `vpc-infrastructure` plugins), `kubectl`, `oc`,
`helm`, `curl`, `tar`, `python3`, `jq`.

To build a local copy from source (for development on the image
itself):

```bash
docker build -t ghcr.io/jgruberf5/ibmcloud-terraform-bnk-2-3:latest .
# Pin a different Terraform version:
docker build --build-arg TERRAFORM_VERSION=1.9.8 \
    -t ghcr.io/jgruberf5/ibmcloud-terraform-bnk-2-3:latest .
```

Or build with any tag and point `bnk` at it:

```bash
docker build -t my-bnk-dev .
IMAGE=my-bnk-dev bnk plan
```

### Why `terraform init` is fast

The build runs `terraform init -backend=false` once against the project
at `/opt/tf-project`, which:

1. **Pins provider versions** in `.terraform.lock.hcl` (shipped in the image).
2. **Pre-fetches every provider** into the shared plugin cache at
   `/opt/tf-project/.terraform-provider-cache` (set via
   `TF_PLUGIN_CACHE_DIR`). At runtime, `terraform init` reads from the
   cache — no registry round-trip.
3. **Resolves local modules** in-place from the image's project tree.

`bnk infra init` writes `.terraform/` to the cwd (via `TF_DATA_DIR`)
and uses the pre-warmed plugin cache, so it completes in seconds and
needs no network. Re-init only when you change `versions.tf` or pull a
newer image (delete `./.terraform/` or run `bnk infra init`).

### State persistence — the current directory

`bnk` bind-mounts your current directory at `/work` inside the
container, runs as the host UID/GID, and consolidates everything bnk
owns under a single `.bnk/` subdirectory. Your cwd looks like this:

```
~/myproject/
├── terraform.tfvars       your input
├── .gitignore             written by `bnk init` to protect secrets
└── .bnk/                  everything bnk owns (one dir, one ignore)
    ├── terraform.tfstate  root-module state
    ├── terraform.tfstate.backup
    ├── terraform/         TF_DATA_DIR — provider links, module cache
    ├── plan.tfplan        short-lived; removed by `bnk plan`
    ├── .kube/config       cluster admin kubeconfig (+ `.cluster-id`)
    ├── .bluemix/          ibmcloud session token + plugins
    └── test-runs/<ts>/    per-run state from `bnk infra test`
```

Run `bnk` from a per-project directory; don't share one cwd across
unrelated deployments. Each directory is its own state.

Wipe a project's state with `bnk delete` — prompts for
confirmation, then `rm -rf .bnk` (`terraform.tfvars` is left alone).

The Terraform project itself — every `.tf` file, the modules, and the
pre-warmed provider cache — lives at `/opt/tf-project` inside the
image and is read-only. `bnk` reaches into it via
`terraform -chdir=/opt/tf-project`.

### Credentials and inputs

`bnk` reads `terraform.tfvars` from the cwd. The entrypoint extracts
`ibmcloud_api_key` and `ibmcloud_cluster_region` and exports them as
`IBMCLOUD_API_KEY` / `IBMCLOUD_REGION` so every shell and one-shot
command inside the container — `bnk shell`, `bnk kubectl …`,
`bnk infra test`, and friends — picks up auth automatically.

You can also set `TF_VAR_ibmcloud_api_key` etc. in your shell to
override; the entrypoint prefers env vars when set.

---

## How `bnk` resolves auth and the cluster

When you run `bnk shell`, `bnk kubectl …`, `bnk oc …`, `bnk ibmcloud …`,
or `bnk status`, bnk transparently runs `ibmcloud login`, fetches an
admin kubeconfig with `ibmcloud ks cluster config --admin`, and caches
both in the docker volume before handing off to your command (or
dropping you into an interactive bash with the cluster name in the
prompt).

Each input is resolved in priority order, stopping at the first hit:

| Value   | Sources (in order) |
|---------|-------------------|
| API key | `IBMCLOUD_API_KEY` env, `TF_VAR_ibmcloud_api_key`, `ibmcloud_api_key` in tfvars |
| Region  | `IBMCLOUD_REGION` env, `TF_VAR_ibmcloud_cluster_region`, `ibmcloud_cluster_region` in tfvars, fallback `ca-tor` |
| Cluster | `bnk shell -c <name>`, `terraform output -raw roks_cluster_id`, `roks_cluster_id_or_name` in tfvars, `openshift_cluster_name` in tfvars |

The kubeconfig is cached at `./.kube/config` in the cwd. Calls within
50 minutes reuse it (skip both `ibmcloud login` and `ibmcloud ks
cluster config`); after that the session is refreshed inside the IBM
IAM token's 1-hour validity window. The `ibmcloud` session and plugin
caches live in the same volume, so warm containers stay authenticated.

---

## State

State is held in a **standard Terraform state file** at
`./.bnk/terraform.tfstate` in your project directory (with the usual
`.backup` sibling). Every resource across every phase lives in this
single state file.

To switch to a remote backend (IBM Cloud Object Storage, Terraform
Cloud, S3, etc.) add a `backend` block to `versions.tf`. Nothing in
the wrapper depends on local state.

---

## Test harness — `bnk infra test`

`bnk infra test` runs `run_tests.sh` inside the container. It exercises
the wrapper through `init → plan → apply → destroy` against four real
IBM Cloud deployment scenarios and reports PASS / FAIL per phase.

### Scenarios

| # | Scenario                                            | `create_roks_cluster` | `create_roks_transit_gateway` | `install_cert_manager` |
|---|-----------------------------------------------------|:---------------------:|:-----------------------------:|:----------------------:|
| 1 | `full`                                              | true                  | true                          | true                   |
| 2 | `existing-cluster-create-tgw`                       | false                 | true                          | true                   |
| 3 | `existing-cluster-existing-tgw`                     | false                 | false                         | true                   |
| 4 | `existing-cluster-create-tgw-existing-cert-manager` | false                 | true                          | false                  |

Each scenario runs from the project root but uses an isolated
`.terraform` directory and state file under `test-runs/<timestamp>/`,
so the project's own state is never touched. Resource names get a
per-run, per-scenario suffix (`-tN-HHMM`) so back-to-back runs don't
conflict in IBM Cloud.

Scenarios 2–4 share a **prereqs workspace** that provisions cluster +
TGW + cert-manager (with `deploy_bnk=false`) once before they start and
tears it down after all three finish. Scenario 1 runs independently.

### Usage

```bash
# Every scenario, with destroy after each
./bnk infra test

# Subset — by number or label
./bnk infra test 1 3
./bnk infra test full existing-cluster-existing-tgw

# Leave resources up after apply (useful for debugging a failure)
./bnk infra test --no-destroy 1

# Custom output directory
./bnk infra test --run-dir /tmp/bnk-test 1

# Recover after a crash — destroy any state still on disk
./bnk infra test --cleanup test-runs/20260504_065205
```

### Safety

The harness registers each `apply` for cleanup and installs an `EXIT`
trap, so Ctrl-C, a `set -e` bailout, or `SIGTERM` triggers an emergency
destroy of every active state file before exit. If the script itself is
killed (`SIGKILL`, host crash) the `--cleanup DIR` mode walks a prior
run directory and destroys any non-empty state files.

The base `terraform.tfvars` is the input template — the harness
generates a per-scenario tfvars file with the necessary overrides; it
never modifies the original.

Per-scenario logs and tfvars land under `test-runs/<UTC-timestamp>/`:

```
test-runs/20260504_065205/
├── summary.log
├── prereqs/                                          # shared (scenarios 2–4)
├── scenario-1-full/
│   ├── terraform_full.tfvars
│   ├── terraform.tfstate
│   ├── phase-init.log
│   ├── phase-plan.log
│   ├── phase-apply.log
│   └── phase-destroy.log
└── ...
```

---

## Maintainers — releasing

Releases are fully automated by `.github/workflows/release.yml`. When a
GitHub release is published, the workflow:

1. Builds the runner image and pushes it to
   `ghcr.io/<owner>/ibmcloud-terraform-bnk-2-3` tagged with both the
   release tag and `latest`.
2. Rewrites the install URL in `README.md` (between the
   `<!-- BNK_INSTALL_URL_BEGIN/END -->` markers) to pin to the new
   tag, then commits the change to `main`.

End users always see a `README.md` and a `bnk` script that match the
latest release.

### One-time setup

After cloning the repo (or forking and cloning your fork), run:

```bash
./setup_ghcr.sh
```

Requires the [`gh` CLI](https://cli.github.com) authenticated as a
user with admin access to the repo. The script:

- Verifies `gh` is installed and authenticated.
- Sets the repo's default workflow permissions to `write` so the
  release workflow can commit README updates back to `main`.
- Reports whether the GHCR package exists and what its visibility is.
- Offers to flip the package to `public` once it exists (so users can
  `docker pull` anonymously).

It's idempotent — safe to re-run any time. You'll re-run it once
after the first release to flip the new package to public.

### Initial release (bootstrap)

The first release is a two-pass dance because the GHCR package
doesn't exist until the first build pushes it:

```bash
# 1. Make sure local state is clean and tests pass.
bnk infra test                   # optional but recommended

# 2. Run one-time repo setup (sets workflow permissions).
./setup_ghcr.sh

# 3. Push everything to main.
git push origin main

# 4. Cut the first release.
gh release create v2.3.0 \
    --title v2.3.0 \
    --notes "Initial release."

# 5. Watch the workflow build, push to ghcr.io, and bump the README.
gh run watch

# 6. The new package is private by default — flip it public so
#    anonymous installs work.
./setup_ghcr.sh                  # re-run; it'll detect the new package
                                 # and offer to make it public
```

After step 6 the install URL printed in `README.md` will pull the
real bnk and the `docker pull` inside `bnk doctor` / `bnk plan` will
hit a public GHCR image. Verify by installing in a scratch dir:

```bash
mkdir /tmp/bnk-test && cd /tmp/bnk-test
curl -fsSL https://raw.githubusercontent.com/jgruberf5/ibmcloud_terraform_bigip_next_for_kubernetes_2_3/v2.3.0/install.sh | bash
bnk doctor
```

### Subsequent releases

Once bootstrapped, a release is a single command:

```bash
git push origin main             # land all changes for the release
gh release create v2.4.0 --title v2.4.0 --notes "$(git log v2.3.0..HEAD --oneline)"
gh run watch                     # ~3-5 minutes for the image build
```

The workflow handles the image push and README install URL bump.
Package visibility carries over from the first release — no need to
re-run `setup_ghcr.sh`.

### What requires a release vs. what doesn't

| Change                                           | Release needed? |
|--------------------------------------------------|:---------------:|
| `bnk` script changes (commands, flags, fixes)    | yes — installs are pinned by tag |
| `install.sh` changes                             | yes — same reason |
| Image content (Dockerfile, baked-in CLIs, providers) | yes — image is tagged with release tag |
| Terraform module changes (anything under `modules/` or `*.tf`) | yes — `.terraform.lock.hcl` and provider cache are baked in at build time |
| README copy edits, project-layout docs, comments | no — push to main; the install URL line is auto-updated on the next release |
| `setup_ghcr.sh`                                  | no — maintainer-only, runs from cwd |

### Versioning

Use [semver](https://semver.org). The project tracks F5 BIG-IP Next
for Kubernetes 2.3.x, so the major + minor follow the upstream
product line; patch and pre-release segments are this wrapper's:

- `v2.3.0`, `v2.3.1` — patch releases for fixes / module updates
- `v2.4.0-beta.1` — pre-release; mark as "Pre-release" in `gh release create --prerelease`
- `v2.4.0` — minor bump for new wrapper features or BIG-IP Next 2.4 support

Pre-release tags do **not** bump the install URL in the README — the
release workflow runs on every published release including
pre-releases, but you can guard with `if: '!github.event.release.prerelease'`
on the `bump-install-url` job if you want pre-releases to leave the
README alone. (Currently the workflow updates on every release.)

### Rolling back

If a release is broken:

1. **Yank the GHCR tag** (so installs fail loudly instead of pulling
   broken code):
   ```bash
   gh api -X DELETE \
     /user/packages/container/ibmcloud-terraform-bnk-2-3/versions/<id>
   ```
   Find the version id with:
   ```bash
   gh api /user/packages/container/ibmcloud-terraform-bnk-2-3/versions \
     --jq '.[] | {id, tags: .metadata.container.tags}'
   ```

2. **Edit the GitHub release** to mark it as draft or delete it
   (`gh release delete v2.3.1 --yes`). The git tag itself can stay or
   be removed (`git push --delete origin v2.3.1`).

3. **Cut a fix release** (`v2.3.2`) following the normal flow. Don't
   reuse the broken tag — semver pins are immutable for downstream
   users who already curl'd the old install URL.

### Things to keep in sync

When changing the image name, owner, or wrapper version:

- `bnk`'s default `IMAGE` (top of file)
- `release.yml`'s `IMAGE_NAME` env var
- `setup_ghcr.sh`'s `IMAGE_NAME` env var default
- `install.sh`'s `REPO_OWNER` / `REPO_NAME` defaults
- `README.md` install URL block + the airgap docker-run example
  (the airgap example isn't auto-updated by the workflow — it's
  outside the install URL markers; bump it by hand on owner changes)

---

## Project layout

```
.
├── bnk                       # the unified CLI (this is the entry point)
├── install.sh                # host installer (curl-able)
├── setup_ghcr.sh             # one-time ghcr.io + repo setup for maintainers
├── .github/workflows/
│   └── release.yml           # build + push to ghcr + bump install URL on release
├── main.tf                   # instantiates and wires the phase modules
├── variables.tf              # root inputs (forwarded to the modules)
├── outputs.tf                # root outputs (surfaced from the modules)
├── providers.tf              # ibm / null / http providers
├── versions.tf               # required Terraform and provider versions
├── terraform.tfvars.example  # template for your terraform.tfvars
├── Dockerfile                # builds the runner image
├── docker-entrypoint.sh      # ENTRYPOINT: symlinks, credential exports, ibmcloud state
├── cloud-exec                # internal helper baked into the image (called by bnk shell/kubectl/oc/ibmcloud)
├── run_tests.sh              # 4-scenario init/plan/apply/destroy test harness
├── remove_cert_manager_crds.sh   # helper: delete cert-manager CRDs (helm uninstall doesn't)
├── .dockerignore
└── modules/
    ├── roks_cluster/
    ├── cert_manager/
    ├── flo/
    ├── cne_instance/
    ├── license/
    └── testing/
```

---

## Requirements

**On the host (running `./bnk`):**

- Docker (Linux, macOS, or WSL2)
- bash 3.2+ (default everywhere — macOS included)
- POSIX coreutils (`cat`, `cp`, `mv`, `rm`, `chmod`, `mkdir`, `head`),
  `awk`, `tr`, `date` — all default on Linux and macOS

That's it. You do **not** need terraform, ibmcloud, kubectl, oc, helm,
jq, or GNU coreutils on the host — every non-default dependency lives
inside the runner image.

**At IBM Cloud:**

- An API key with permissions for VPC, ROKS, Transit Gateway, COS, and
  IAM trusted profiles in the target resource group
- Access to the F5 FAR repository and the COS bucket holding the FAR
  auth key and subscription JWT (see the `flo` / `license` sections in
  `terraform.tfvars.example`)
