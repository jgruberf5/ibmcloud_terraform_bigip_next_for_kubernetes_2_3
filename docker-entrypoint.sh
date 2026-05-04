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

exec "$@"
