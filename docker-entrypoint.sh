#!/usr/bin/env bash
# ============================================================
# docker-entrypoint.sh
#
# bnk runs the image with the host's current directory bind-mounted at
# /work, so the user's project dir is the source of truth for both
# inputs (terraform.tfvars) and outputs (tfstate, .terraform, .kube,
# .bluemix, test-runs/). The Terraform project itself lives at
# /opt/tf-project — read-only from the image; bnk reaches into it via
# `terraform -chdir=/opt/tf-project`.
#
# This entrypoint exists only to:
#   1. Read tfvars (if mounted) and export IBMCLOUD_API_KEY /
#      IBMCLOUD_REGION so every shell inside the container has live
#      auth without re-prompting.
#   2. Pin KUBECONFIG to /work/.kube/config so kubectl/oc share the
#      same cached kubeconfig as cloud-exec.
#   3. exec the user's command.
#
# It deliberately does NOT:
#   - symlink files from /opt/tf-project into /work (those would
#     dangle on the host with a bind-mounted cwd),
#   - run `terraform init` (bnk drives that explicitly when needed),
#   - manipulate /root/.bluemix (we run as the host user; HOME is set
#     to /work by bnk so caches land in the user's cwd).
# ============================================================
set -euo pipefail

WORK_DIR="${WORK_DIR:-/work}"
TFVARS="$WORK_DIR/terraform.tfvars"

read_tfvar() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 0
    awk -F'"' "/^[[:space:]]*$key[[:space:]]*=/{print \$2; exit}" "$file"
}

# Resolve the IBM Cloud API key from any of the conventional env vars
# users (or their CI runners) set, with terraform.tfvars as the final
# fallback. Whichever is found is exported as IBMCLOUD_API_KEY so
# `ibmcloud login`, cloud-exec, and the IBM terraform provider all
# pick it up uniformly.
if [[ -z "${IBMCLOUD_API_KEY:-}" ]]; then
    for _v in IC_API_KEY \
              TF_VAR_ibmcloud_api_key \
              TF_VAR_IBMCLOUD_API_KEY \
              TF_VAR_IC_API_KEY; do
        if [[ -n "${!_v:-}" ]]; then
            export IBMCLOUD_API_KEY="${!_v}"
            break
        fi
    done
    unset _v
fi
if [[ -z "${IBMCLOUD_API_KEY:-}" ]]; then
    export IBMCLOUD_API_KEY="$(read_tfvar ibmcloud_api_key "$TFVARS")"
fi

if [[ -z "${IBMCLOUD_REGION:-}" ]]; then
    export IBMCLOUD_REGION="${TF_VAR_ibmcloud_cluster_region:-$(read_tfvar ibmcloud_cluster_region "$TFVARS")}"
fi
: "${IBMCLOUD_REGION:=ca-tor}"
export IBMCLOUD_REGION

# bnk passes KUBECONFIG explicitly via -e. For users running the image
# directly, default to the .bnk-aware path so cloud-exec and kubectl
# share the same kubeconfig location.
export KUBECONFIG="${KUBECONFIG:-$WORK_DIR/.bnk/.kube/config}"

# Disable ibmcloud's interactive update prompt. On a TTY (bnk uses
# `docker run -it`), `ibmcloud login` prints "New version X.Y.Z is
# available... Do you want to update? [y/N]" and waits for input.
# Answering 'y' invokes the install script which calls sudo (not
# present in this image — and the runtime user is non-root anyway),
# fails 127, and leaves the install half-applied.
export IBMCLOUD_VERSION_CHECK="${IBMCLOUD_VERSION_CHECK:-false}"

# Seed the user's .bluemix from the build-time template on first run.
# Plugins (ks, vpc-infrastructure) and the --check-version=false
# config are installed under /opt/ibmcloud-template/.bluemix in the
# Dockerfile (world-readable).
#
# Per-item, not `cp -rn ... /. ...`: busybox cp's -n on a directory
# source bails out entirely when the destination dir already exists
# (vs GNU cp's per-file no-clobber). Test each item ourselves so
# missing pieces fill in without touching anything the user already
# has — login may have updated config.json with creds.
if [[ -d /opt/ibmcloud-template/.bluemix ]]; then
    mkdir -p "$WORK_DIR/.bnk/.bluemix"
    [[ -e "$WORK_DIR/.bnk/.bluemix/plugins" ]] \
        || cp -r /opt/ibmcloud-template/.bluemix/plugins "$WORK_DIR/.bnk/.bluemix/plugins"
    [[ -e "$WORK_DIR/.bnk/.bluemix/config.json" ]] \
        || cp /opt/ibmcloud-template/.bluemix/config.json "$WORK_DIR/.bnk/.bluemix/config.json"
fi

# Pre-create the per-module kubeconfig dirs. ibm_container_cluster_config
# expects config_dir to exist (it does NOT MkdirAll) and emits "Path:
# <dir>, to download the config doesn't exist" otherwise. Module names
# mirror the TF layout in modules/{cert_manager,cne_instance,flo,license}/
# providers.tf — var.kubeconfig_dir defaults match these paths. Belt-
# and-suspenders alongside bnk's ensure_workspace so non-bnk users
# (e.g. running the image directly) get the dirs too.
mkdir -p "$WORK_DIR/.bnk/scratch/kubeconfig"/{cert_manager,cne_instance,flo,license}

cd "$WORK_DIR" 2>/dev/null || true

exec "$@"
