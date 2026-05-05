#!/usr/bin/env bash
# ============================================================
# docker-entrypoint.sh
#
# The container ships the Terraform project at /opt/tf-project
# (read-only source of truth, with .terraform/ and the provider
# cache pre-populated by `terraform init` during the build).
#
# At runtime we work from /work — a Docker volume that holds the
# user's mutable state (terraform.tfstate, test-runs/, and any
# tfvars they supplied).  This entrypoint populates /work with
# symlinks back to /opt/tf-project so terraform finds the .tf
# files, modules, lockfile, and provider cache, while leaving
# the genuinely mutable paths as real files/dirs in the volume.
# ============================================================

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/tf-project}"
WORK_DIR="${WORK_DIR:-/work}"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Names that must remain real files/dirs in the volume.  Symlinking
# terraform.tfstate would break terraform's atomic-rename writes
# (rename(2) replaces the symlink with a regular file, so the write
# never reaches the volume).  test-runs/ is the run_tests.sh output
# tree; .terraform/ is per-workdir and is recreated lazily.
SKIP=" terraform.tfstate terraform.tfstate.backup test-runs .terraform "

shopt -s nullglob dotglob
for entry in "$PROJECT_DIR"/*; do
    name=$(basename "$entry")
    case "$name" in . | ..) continue ;; esac
    [[ "$SKIP" == *" $name "* ]] && continue

    if [[ -L "$name" ]]; then
        # Refresh stale links so image upgrades take effect even when
        # the volume already has links from a previous container.
        rm -f "$name"
    elif [[ -e "$name" ]]; then
        # Real file already in the volume (e.g. a user-supplied
        # terraform.tfvars or an edited script) — leave it untouched.
        continue
    fi
    ln -s "$entry" "$name"
done
shopt -u nullglob dotglob

# Provide a usable .terraform/ in the workdir so `terraform plan`
# works without the user having to run `terraform init` first.  The
# plugin cache is pre-populated, so this is fast and offline-safe.
if [[ ! -d "$WORK_DIR/.terraform" ]]; then
    terraform init -input=false -no-color >/dev/null 2>&1 || true
fi

# Resolve IBM Cloud credentials and KUBECONFIG defaults from env vars
# or /work/terraform.tfvars so EVERY shell inside the container picks
# them up — including `./build.sh shell`, plain `docker run … bash`,
# and cloud-exec.  With IBMCLOUD_API_KEY exported here, `ibmcloud login`
# never falls back to the email/password prompt.
read_tfvar() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 0
    awk -F'"' "/^[[:space:]]*$key[[:space:]]*=/{print \$2; exit}" "$file"
}
TFVARS="$WORK_DIR/terraform.tfvars"

if [[ -z "${IBMCLOUD_API_KEY:-}" ]]; then
    export IBMCLOUD_API_KEY="${TF_VAR_ibmcloud_api_key:-$(read_tfvar ibmcloud_api_key "$TFVARS")}"
fi
if [[ -z "${IBMCLOUD_REGION:-}" ]]; then
    export IBMCLOUD_REGION="${TF_VAR_ibmcloud_cluster_region:-$(read_tfvar ibmcloud_cluster_region "$TFVARS")}"
fi
: "${IBMCLOUD_REGION:=ca-tor}"
export IBMCLOUD_REGION

# kubectl / oc read $KUBECONFIG. Pin it to a stable path inside the volume
# so the kubeconfig survives container restarts and is shared by both CLIs.
export KUBECONFIG="${KUBECONFIG:-$WORK_DIR/.kube/config}"
mkdir -p "$(dirname "$KUBECONFIG")"

# ibmcloud stores its session in ~/.bluemix/config.json plus the plugin
# directories.  Without the symlink below this state lives in the
# container's writable layer and is lost on `--rm`, forcing a fresh
# auto-login on every container.  Migrate the image's plugins into the
# /work volume on first use, then symlink /root/.bluemix to that path
# so login state, plugin caches, and cluster downloads all persist.
HOME_BLUEMIX="${HOME:-/root}/.bluemix"
WORK_BLUEMIX="$WORK_DIR/.bluemix"
if [[ ! -L "$HOME_BLUEMIX" ]]; then
    if [[ ! -d "$WORK_BLUEMIX" && -d "$HOME_BLUEMIX" ]]; then
        cp -a "$HOME_BLUEMIX" "$WORK_BLUEMIX"
    else
        mkdir -p "$WORK_BLUEMIX"
    fi
    rm -rf "$HOME_BLUEMIX"
    ln -s "$WORK_BLUEMIX" "$HOME_BLUEMIX"
fi

exec "$@"
