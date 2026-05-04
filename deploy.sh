#!/usr/bin/env bash
set -euo pipefail

if [ -t 0 ]; then
  terraform apply -var-file terraform.tfvars
else
  terraform apply -var-file terraform.tfvars -auto-approve
fi
