# syntax=docker/dockerfile:1
# ============================================================
# F5 BIG-IP Next for Kubernetes 2.3 — Terraform runner
#
# Smallest Alpine-based image that can run:
#   - terraform (CLI)
#   - ./run_tests.sh
#
# Modules call out to kubectl / helm / curl / tar via local-exec
# during apply, so those CLIs are installed too.  python3 is
# required by run_tests.sh's tfvars helpers.  ibmcloud and oc are
# included for interactive use (login, kubeconfig fetch, OpenShift
# inspection); they are dynamically linked against glibc so gcompat
# is installed alongside them on musl-based Alpine.  All providers
# and the .terraform.lock.hcl are baked in via `terraform init`
# during the build, so runtime needs no registry access.
# ============================================================

FROM alpine:3.19

ARG TERRAFORM_VERSION=1.9.8
ARG ALPINE_VERSION=3.19
ARG OC_VERSION=stable-4.18
ARG IBMCLOUD_CLI_VERSION=2.27.0

# kubectl and helm live in the alpine community repository.
# gcompat provides the glibc shim ibmcloud and oc need on musl.
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >> /etc/apk/repositories \
    && apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        gcompat \
        helm \
        jq \
        kubectl \
        python3 \
        tar \
    && apk add --no-cache --virtual .build-deps unzip \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
            -o /tmp/terraform.zip \
    && unzip -q /tmp/terraform.zip -d /usr/local/bin/ \
    && rm /tmp/terraform.zip \
    && apk del .build-deps

# IBM Cloud CLI — install from the IBM download directly so the install
# step is just file extraction (the `curl | sh` script's tail end invokes
# `ibmcloud --version` for verification, which can fail on Alpine even
# with gcompat).  We then:
#   * `find` for the binary (the tarball ships it at either the top level
#     or under bin/ across versions),
#   * create the /lib64/ld-linux-x86-64.so.2 symlink that glibc binaries'
#     PT_INTERP hard-codes (gcompat provides /lib/ld-linux-x86-64.so.2 on
#     musl Alpine but does not parallel it under /lib64/),
#   * verify with `ibmcloud --version`.
# If the binary is missing the build prints the extracted tree so the
# next iteration can fix the path quickly.  Plugins go in a separate RUN
# so a failure there doesn't force re-downloading the CLI tarball.
RUN curl -fsSL "https://download.clis.cloud.ibm.com/ibm-cloud-cli/${IBMCLOUD_CLI_VERSION}/IBM_Cloud_CLI_${IBMCLOUD_CLI_VERSION}_amd64.tar.gz" \
            -o /tmp/ibmcloud.tar.gz \
    && mkdir -p /usr/local/ibmcloud \
    && tar -xzf /tmp/ibmcloud.tar.gz -C /usr/local/ibmcloud --strip-components=1 \
    && rm /tmp/ibmcloud.tar.gz \
    && IBMCLOUD_BIN=$(find /usr/local/ibmcloud -maxdepth 3 -type f -name ibmcloud | head -1) \
    && [ -n "$IBMCLOUD_BIN" ] || { echo "ibmcloud binary not found in tarball; layout was:"; find /usr/local/ibmcloud | head -50; exit 1; } \
    && ln -sf "$IBMCLOUD_BIN" /usr/local/bin/ibmcloud \
    && mkdir -p /lib64 \
    && ln -sf /lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2 \
    && ibmcloud --version

# IBM Cloud CLI plugins:
#   container-service   for ROKS / IKS — also exposes `ibmcloud oc` for
#                       OpenShift commands (the alias is kubernetes-service / ks)
#   vpc-infrastructure  for VPC operations
RUN ibmcloud config --check-version false \
    && ibmcloud plugin install container-service -f \
    && ibmcloud plugin install vpc-infrastructure -f

# OpenShift `oc` CLI — pinned to the latest 4.18.x via the mirror's
# stable-4.18 channel so commands stay compatible with the
# openshift_cluster_version default. Override with --build-arg
# OC_VERSION=stable-4.19 (or an exact version like 4.18.21) when the
# cluster minor changes. The tarball also ships kubectl; we extract
# only `oc` to avoid clobbering the alpine-managed kubectl above.
RUN curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OC_VERSION}/openshift-client-linux.tar.gz" \
            -o /tmp/oc.tar.gz \
    && tar -xzf /tmp/oc.tar.gz -C /usr/local/bin/ oc \
    && chmod 0755 /usr/local/bin/oc \
    && rm /tmp/oc.tar.gz

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
    && chmod +x ${PROJECT_DIR}/run_tests.sh \
                 ${PROJECT_DIR}/docker-entrypoint.sh \
                 ${PROJECT_DIR}/cloud-exec \
                 ${PROJECT_DIR}/bnk \
    && ln -sf ${PROJECT_DIR}/cloud-exec /usr/local/bin/cloud-exec \
    && ln -sf ${PROJECT_DIR}/bnk        /usr/local/bin/bnk

# Mutable workdir backed by a Docker volume at runtime.
WORKDIR ${WORK_DIR}
VOLUME ["${WORK_DIR}"]

ENTRYPOINT ["/opt/tf-project/docker-entrypoint.sh"]
CMD ["terraform", "--help"]
