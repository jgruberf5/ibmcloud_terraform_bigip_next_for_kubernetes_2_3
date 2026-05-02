# ============================================================
# Root Terraform Variables
# F5 BNK Orchestrator for existing ROKS cluster
# ============================================================


# ============================================================
# IBM Cloud Variables
# ============================================================

variable "ibmcloud_api_key" {
  description = "IBM Cloud API Key"
  type        = string
  sensitive   = true
}

variable "ibmcloud_cluster_region" {
  description = "IBM Cloud region where the cluster resides"
  type        = string
  default     = "ca-tor"
}

variable "ibmcloud_resource_group" {
  description = "IBM Cloud Resource Group name (leave empty to use account default)"
  type        = string
  default     = "default"
}

variable "ibmcloud_cos_bucket_region" {
  description = "IBM Cloud region where the COS bucket is located"
  type        = string
  default     = "us-south"
}

variable "ibmcloud_cos_instance_name" {
  description = "IBM Cloud COS instance name"
  type        = string
  default     = "bnk-orchestration"
}

variable "ibmcloud_resources_cos_bucket" {
  description = "IBM Cloud COS bucket containing the FAR auth key and JWT files"
  type        = string
  default     = "bnk-schematics-resources"
}

# ============================================================
# ROKs Output
# ============================================================

variable "roks_cluster_name_or_id" {
  description = "Name or ID of the existing OpenShift ROKS cluster to deploy BNK onto"
  type        = string

  validation {
    condition     = length(var.roks_cluster_name_or_id) > 0
    error_message = "roks_cluster_name_or_id cannot be empty — an existing cluster is required."
  }
}


# ============================================================
# FLO Output
# ============================================================

variable "flo_utils_namespace" {
  description = "Namespace for F5 utility components"
  type        = string
  default     = "f5-utils"
}

# ============================================================
# License Configuration
# ============================================================

variable "f5_cne_subscription_jwt_file" {
  description = "Subscription JWT filename in the COS bucket"
  type        = string
  default     = "trial.jwt"
}

variable "license_mode" {
  description = "License operation mode (connected or disconnected)"
  type        = string
  default     = "connected"
}

variable "create_roks_cluster" {
  description = "When true, cluster is being created by ws1 — skip plan-time cluster credential fetch"
  type        = bool
  default     = false
}

variable "ws1_dependency_id" {
  description = "ws1 sentinel ID — when set, defers runtime_config fetch to apply time after ws1 completes"
  type        = string
  default     = null
}

variable "cneinstance_dependency_id" {
  description = "cneinstance_ready_id from ws4 — when set, ensures License CRD is available before applying License CR"
  type        = string
  default     = null
}
