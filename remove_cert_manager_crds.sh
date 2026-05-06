#!/usr/bin/env bash
# Remove cert-manager CRDs after a cluster cleanup. cert-manager's CRDs
# are not deleted by `helm uninstall`, so a re-install (or destroy +
# re-apply with install_cert_manager=true) trips on stale CRDs.
set -euo pipefail
./bnk cluster oc delete crd \
  certificaterequests.cert-manager.io \
  certificates.cert-manager.io \
  challenges.acme.cert-manager.io \
  clusterissuers.cert-manager.io \
  issuers.cert-manager.io \
  orders.acme.cert-manager.io
