# syntax=docker/dockerfile:1
# ============================================================
# F5 BIG-IP Next for Kubernetes 2.3 — Terraform runner
#
# Smallest Alpine-based image that can run:
#   - terraform (CLI)
#   - ./deploy.sh
#   - ./run_tests.sh
#
# Modules call out to kubectl / helm / curl / tar via local-exec
# during apply, so those CLIs are installed too.  python3 is
# required by run_tests.sh's tfvars helpers.  All providers and
# the .terraform.lock.hcl are baked in via `terraform init`
# during the build, so runtime needs no registry access.
# ============================================================

FROM alpine:3.19

ARG TERRAFORM_VERSION=1.9.8
ARG ALPINE_VERSION=3.19

# kubectl and helm live in the alpine community repository.
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >> /etc/apk/repositories \
    && apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        helm \
        kubectl \
        python3 \
        tar \
    && apk add --no-cache --virtual .build-deps unzip \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
            -o /tmp/terraform.zip \
    && unzip -q /tmp/terraform.zip -d /usr/local/bin/ \
    && rm /tmp/terraform.zip \
    && apk del .build-deps

ENV PROJECT_DIR=/opt/tf-project \
    WORK_DIR=/work
ENV TF_PLUGIN_CACHE_DIR=${PROJECT_DIR}/.terraform-provider-cache

WORKDIR ${PROJECT_DIR}
COPY . ${PROJECT_DIR}/

# Pre-fetch every provider into the shared plugin cache and write
# the lock file.  -backend=false skips backend init (this project
# uses local state).  run_tests.sh reuses the same cache so per-
# scenario `terraform init` is a no-network operation.
RUN mkdir -p "${TF_PLUGIN_CACHE_DIR}" \
    && terraform init -backend=false -input=false \
    && chmod +x ${PROJECT_DIR}/deploy.sh \
                 ${PROJECT_DIR}/run_tests.sh \
                 ${PROJECT_DIR}/docker-entrypoint.sh

# Mutable workdir backed by a Docker volume at runtime.
WORKDIR ${WORK_DIR}
VOLUME ["${WORK_DIR}"]

ENTRYPOINT ["/opt/tf-project/docker-entrypoint.sh"]
CMD ["terraform", "--help"]
