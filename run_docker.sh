#!/usr/bin/env bash
# ============================================================
# run_docker.sh — convenience wrapper around the runner image
#
# Demonstrates every common workflow against the
# ibmcloud-terraform-bnk-2-3 image.  All docker volume and
# bind-mount details live in this script so README examples can
# stay short.
#
# Pre-reqs:
#   - Image built:  docker build -t ibmcloud-terraform-bnk-2-3 .
#   - terraform.tfvars in the current directory
#
# Usage:
#   ./run_docker.sh init                # terraform init
#   ./run_docker.sh plan                # terraform plan
#   ./run_docker.sh apply               # terraform apply (interactive)
#   ./run_docker.sh deploy              # ./deploy.sh wrapper inside container
#   ./run_docker.sh destroy             # terraform destroy
#   ./run_docker.sh output [name]       # terraform output
#   ./run_docker.sh test [args...]      # ./run_tests.sh inside container
#   ./run_docker.sh cloud-exec [cmd...] # ibmcloud/kubectl/oc with auth set
#                                       # up; interactive bash if no cmd
#   ./run_docker.sh shell               # plain bash inside container
#   ./run_docker.sh exec <cmd...>       # arbitrary one-shot command
#   ./run_docker.sh -h | --help
#
# Examples:
#   ./run_docker.sh apply
#   ./run_docker.sh cloud-exec kubectl get pods -A
#   ./run_docker.sh cloud-exec oc adm top nodes
#   ./run_docker.sh cloud-exec ibmcloud ks cluster ls
#   ./run_docker.sh test --no-destroy 1
#
# Environment overrides:
#   IMAGE   image tag to run (default: ibmcloud-terraform-bnk-2-3)
#   VOLUME  docker volume holding state + caches (default: bnk-state)
# ============================================================
set -euo pipefail

IMAGE="${IMAGE:-ibmcloud-terraform-bnk-2-3}"
VOLUME="${VOLUME:-bnk-state}"

[[ -f "$(pwd)/terraform.tfvars" ]] || {
    echo "run_docker.sh: terraform.tfvars not found in $(pwd)" >&2
    exit 1
}

docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null

run_in_container() {
    docker run -it --rm \
        -v "$VOLUME:/work" \
        -v "$(pwd)/terraform.tfvars:/work/terraform.tfvars:ro" \
        "$IMAGE" "$@"
}

CMD="${1:-help}"; shift || true

case "$CMD" in
    init)        run_in_container terraform init "$@" ;;
    plan)        run_in_container terraform plan    -var-file=terraform.tfvars "$@" ;;
    apply)       run_in_container terraform apply   -var-file=terraform.tfvars "$@" ;;
    destroy)     run_in_container terraform destroy -var-file=terraform.tfvars "$@" ;;
    output)      run_in_container terraform output "$@" ;;
    deploy)      run_in_container ./deploy.sh ;;
    test|tests)  run_in_container ./run_tests.sh "$@" ;;
    shell|bash)  run_in_container bash ;;
    cloud-exec)  run_in_container cloud-exec "$@" ;;
    exec)        run_in_container "$@" ;;
    -h|--help|help)
        sed -n '2,/^[^#]/{/^#/!q; s/^# \{0,2\}//p}' "$0"
        ;;
    *)
        echo "run_docker.sh: unknown command '$CMD' — see ./run_docker.sh --help" >&2
        exit 1
        ;;
esac
