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
ARG OC_VERSION=4.18

# kubectl and helm live in the alpine community repository.
# gcompat provides the glibc shim ibmcloud and oc need on musl.
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >> /etc/apk/repositories \
    && apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        gcompat \
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

# IBM Cloud CLI + the same plugins the testing jumphost installs
# (container-service for ROKS, openshift for `ibmcloud oc`, and
# vpc-infrastructure for VPC operations).
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | sh \
    && ibmcloud config --check-version=false \
    && ibmcloud plugin install container-service -f \
    && ibmcloud plugin install openshift -f \
    && ibmcloud plugin install vpc-infrastructure -f

# OpenShift `oc` CLI — pinned to the cluster's minor (4.18) so commands
# stay compatible with the openshift_cluster_version default. The tarball
# also ships kubectl; we extract only `oc` to avoid clobbering the
# alpine-managed kubectl above.
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
    && chmod +x ${PROJECT_DIR}/deploy.sh \
                 ${PROJECT_DIR}/run_tests.sh \
                 ${PROJECT_DIR}/docker-entrypoint.sh \
                 ${PROJECT_DIR}/cloud-exec \
    && ln -sf ${PROJECT_DIR}/cloud-exec /usr/local/bin/cloud-exec

# Mutable workdir backed by a Docker volume at runtime.
WORKDIR ${WORK_DIR}
VOLUME ["${WORK_DIR}"]

ENTRYPOINT ["/opt/tf-project/docker-entrypoint.sh"]
CMD ["terraform", "--help"]
