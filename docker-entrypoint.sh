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

if [[ -z "${IBMCLOUD_API_KEY:-}" ]]; then
    export IBMCLOUD_API_KEY="${TF_VAR_ibmcloud_api_key:-$(read_tfvar ibmcloud_api_key "$TFVARS")}"
fi
if [[ -z "${IBMCLOUD_REGION:-}" ]]; then
    export IBMCLOUD_REGION="${TF_VAR_ibmcloud_cluster_region:-$(read_tfvar ibmcloud_cluster_region "$TFVARS")}"
fi
: "${IBMCLOUD_REGION:=ca-tor}"
export IBMCLOUD_REGION

export KUBECONFIG="${KUBECONFIG:-$WORK_DIR/.kube/config}"
mkdir -p "$(dirname "$KUBECONFIG")" 2>/dev/null || true

cd "$WORK_DIR" 2>/dev/null || true

exec "$@"
