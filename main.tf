# ============================================================
# F5 BIG-IP Next for Kubernetes 2.3 — Direct Terraform Project
#
# This project calls the ws1–ws6 sub-repos as Terraform modules.
# Terraform's dependency graph enforces execution order:
#
#   ws1 (roks_cluster) ──► ws2 (cert_manager) ──► ws3 (flo)
#                      └──────────────────────────► ws4 (cneinstance)  ← also wired from ws3 outputs
#                      └──────────────────────────► ws5 (license)      ← depends on ws4 completing
#                      └──────────────────────────► ws6 (testing)      ← runs last
#
# Cross-module wiring (apply-time ordering enforced via shared output→input):
#   ws1.roks_cluster_name         → ws2/ws3/ws4/ws5/ws6 roks_cluster_name_or_id
#   ws1.roks_transit_gateway_name → ws6 testing_transit_gateway_name
#   ws2.cert_manager_namespace    → ws3 cert_manager_namespace  (ws2→ws3 ordering)
#   ws3.flo_namespace             → ws4 flo_namespace
#   ws3.flo_trusted_profile_id    → ws4 flo_trusted_profile_id  (ws3→ws4 ordering)
#   ws3.flo_cluster_issuer_name   → ws4 flo_cluster_issuer_name
#   ws3.cneinstance_network_attachments → ws4 cneinstance_network_attachments
#
# Ordering NOT enforced by the dependency graph:
#   ws1→ws2, ws1→ws5, ws1→ws6, ws4→ws5
#   If these modules fail on a fresh apply, re-run `terraform apply` once
#   ws1 (and ws4 for ws5) are complete.
#
# Legacy module compatibility note:
#   All sub-repos define their own provider blocks (ibm, kubernetes, helm, etc.)
#   making them "legacy modules" in Terraform's terms.  Legacy modules cannot
#   accept `providers`, `count`, `for_each`, or `depends_on` in the calling
#   module block.  Each module self-configures its IBM provider from the
#   ibmcloud_api_key and ibmcloud_cluster_region input variables.
# ============================================================


# ============================================================
# WS1 — ROKS Cluster 4.18 + Transit Gateway
# ============================================================

module "ws1_roks_cluster" {
  source = "github.com/f5devcentral/ibmcloud_schematics_bigip_next_for_kubernetes_roks_cluster_4?ref=main"

  ibmcloud_api_key                  = var.ibmcloud_api_key
  ibmcloud_cluster_region           = var.ibmcloud_cluster_region
  ibmcloud_resource_group           = var.ibmcloud_resource_group
  create_roks_cluster               = var.create_roks_cluster
  create_roks_transit_gateway       = var.create_roks_transit_gateway
  create_roks_registry_cos_instance = var.create_roks_registry_cos_instance
  roks_cluster_vpc_name             = var.roks_cluster_vpc_name
  openshift_cluster_name            = var.openshift_cluster_name
  openshift_cluster_version         = var.openshift_cluster_version
  roks_workers_per_zone             = var.roks_workers_per_zone
  roks_min_worker_vcpu_count        = var.roks_min_worker_vcpu_count
  roks_min_worker_memory_gb         = var.roks_min_worker_memory_gb
  roks_cos_instance_name            = var.roks_cos_instance_name
  roks_transit_gateway_name         = var.roks_transit_gateway_name
}

# ============================================================
# WS1 Completion Sentinel
# ============================================================
# When create_roks_cluster = true, the cluster ID is only known
# after ws1 applies.  Storing it in a null_resource trigger means
# ws1_sentinel.id is (known after apply), so any downstream module
# that receives ws1_sentinel_id as an input creates a real
# apply-time dependency on ws1 completing — without breaking
# plan-time (provider configs still use the known cluster name).
resource "null_resource" "ws1_sentinel" {
  count = var.create_roks_cluster ? 1 : 0
  triggers = {
    cluster_id          = module.ws1_roks_cluster.roks_cluster_id
    transit_gateway_id  = var.create_roks_transit_gateway ? module.ws1_roks_cluster.roks_transit_gateway_id : "none"
  }
}

locals {
  # Cluster/TGW name strings remain known at plan time so downstream
  # provider configs (ibm_container_cluster_config) can be evaluated.
  ws1_roks_cluster_name    = var.create_roks_cluster ? var.openshift_cluster_name : var.roks_cluster_id_or_name
  ws1_transit_gateway_name = var.roks_transit_gateway_name

  # ID is (known after apply) when creating; null when cluster already exists.
  # Downstream modules use this to gate apply-time execution on ws1 finishing.
  ws1_sentinel_id = var.create_roks_cluster ? null_resource.ws1_sentinel[0].id : null
}


# ============================================================
# WS2 — cert-manager
# ============================================================

module "ws2_cert_manager" {
  source = "./modules/ws2_cert_manager"

  ibmcloud_api_key        = var.ibmcloud_api_key
  ibmcloud_cluster_region = var.ibmcloud_cluster_region
  ibmcloud_resource_group = var.ibmcloud_resource_group
  roks_cluster_name_or_id = local.ws1_roks_cluster_name
  cert_manager_namespace  = var.cert_manager_namespace
  cert_manager_version    = var.cert_manager_version
  create_roks_cluster     = var.create_roks_cluster
  ws1_dependency_id       = local.ws1_sentinel_id
}


# ============================================================
# WS3 — F5 Lifecycle Operator (FLO)
# ============================================================

module "ws3_flo" {
  source = "./modules/ws3_flo"

  ibmcloud_api_key              = var.ibmcloud_api_key
  ibmcloud_cluster_region       = var.ibmcloud_cluster_region
  ibmcloud_resource_group       = var.ibmcloud_resource_group
  roks_cluster_name_or_id       = local.ws1_roks_cluster_name
  cert_manager_namespace        = module.ws2_cert_manager.cert_manager_namespace
  far_repo_url                  = var.far_repo_url
  f5_bigip_k8s_manifest_version = var.f5_bigip_k8s_manifest_version
  use_cos_bucket                = true
  ibmcloud_cos_bucket_region    = var.ibmcloud_cos_bucket_region
  ibmcloud_cos_instance_name    = var.ibmcloud_cos_instance_name
  ibmcloud_resources_cos_bucket = var.ibmcloud_resources_cos_bucket
  f5_cne_far_auth_file          = var.f5_cne_far_auth_file
  f5_cne_subscription_jwt_file  = var.f5_cne_subscription_jwt_file
  flo_namespace                 = var.flo_namespace
  flo_utils_namespace           = var.flo_utils_namespace
  bigip_username                = var.bigip_username
  bigip_password                = var.bigip_password
  bigip_url                     = var.bigip_url
  create_roks_cluster           = var.create_roks_cluster
  ws1_dependency_id             = local.ws1_sentinel_id
}

locals {
  # Wire ws3 outputs into ws4 inputs, falling back to root variables when the
  # output isn't yet in state.
  ws3_flo_namespace                   = try(module.ws3_flo.flo_namespace, var.flo_namespace)
  ws3_flo_trusted_profile_id          = try(module.ws3_flo.flo_trusted_profile_id, var.flo_trusted_profile_id)
  ws3_flo_cluster_issuer_name         = try(module.ws3_flo.flo_cluster_issuer_name, var.flo_cluster_issuer_name)
  ws3_cneinstance_network_attachments = try(module.ws3_flo.cneinstance_network_attachments, var.cneinstance_network_attachments)
}


# ============================================================
# WS4 — CNEInstance
# ============================================================

module "ws4_cneinstance" {
  source = "./modules/ws4_cneinstance"

  ibmcloud_api_key                 = var.ibmcloud_api_key
  ibmcloud_cluster_region          = var.ibmcloud_cluster_region
  ibmcloud_resource_group          = var.ibmcloud_resource_group
  roks_cluster_name_or_id          = local.ws1_roks_cluster_name
  far_repo_url                     = var.far_repo_url
  flo_namespace                    = local.ws3_flo_namespace
  flo_utils_namespace              = var.flo_utils_namespace
  f5_bigip_k8s_manifest_version    = var.f5_bigip_k8s_manifest_version
  flo_trusted_profile_id           = local.ws3_flo_trusted_profile_id
  flo_cluster_issuer_name          = local.ws3_flo_cluster_issuer_name
  cneinstance_deployment_size      = var.cneinstance_deployment_size
  cneinstance_gslb_datacenter_name = var.cneinstance_gslb_datacenter_name
  cneinstance_network_attachments  = local.ws3_cneinstance_network_attachments
  create_roks_cluster              = var.create_roks_cluster
  ws1_dependency_id                = local.ws1_sentinel_id
}


# ============================================================
# WS5 — License
# ============================================================

module "ws5_license" {
  source    = "./modules/ws5_license"
  providers = { http = http }

  ibmcloud_api_key              = var.ibmcloud_api_key
  ibmcloud_cluster_region       = var.ibmcloud_cluster_region
  ibmcloud_resource_group       = var.ibmcloud_resource_group
  ibmcloud_cos_bucket_region    = var.ibmcloud_cos_bucket_region
  ibmcloud_cos_instance_name    = var.ibmcloud_cos_instance_name
  ibmcloud_resources_cos_bucket = var.ibmcloud_resources_cos_bucket
  roks_cluster_name_or_id       = local.ws1_roks_cluster_name
  flo_utils_namespace           = var.flo_utils_namespace
  f5_cne_subscription_jwt_file  = var.f5_cne_subscription_jwt_file
  license_mode                  = var.license_mode
  create_roks_cluster           = var.create_roks_cluster
  ws1_dependency_id             = local.ws1_sentinel_id
  cneinstance_dependency_id     = module.ws4_cneinstance.cneinstance_ready_id
}


# ============================================================
# WS6 — Testing Jumphosts
# ============================================================

module "ws6_testing" {
  source = "./modules/ws6_testing"

  ibmcloud_api_key                     = var.ibmcloud_api_key
  ibmcloud_cluster_region              = var.ibmcloud_cluster_region
  ibmcloud_resource_group              = var.ibmcloud_resource_group
  roks_cluster_name_or_id              = local.ws1_roks_cluster_name
  testing_transit_gateway_name         = local.ws1_transit_gateway_name
  testing_create_tgw_jumphost          = var.testing_create_tgw_jumphost
  testing_create_cluster_jumphosts     = var.testing_create_cluster_jumphosts
  testing_ssh_key_name                 = var.testing_ssh_key_name
  testing_jumphost_profile             = var.testing_jumphost_profile
  testing_min_vcpu_count               = var.testing_min_vcpu_count
  testing_min_memory_gb                = var.testing_min_memory_gb
  testing_create_client_vpc            = var.testing_create_client_vpc
  testing_client_vpc_name              = var.testing_client_vpc_name
  testing_client_vpc_region            = var.testing_client_vpc_region
  testing_tgw_jumphost_name            = var.testing_tgw_jumphost_name
  testing_cluster_jumphost_name_prefix = var.testing_cluster_jumphost_name_prefix
  ws1_dependency_id                    = local.ws1_sentinel_id
  create_roks_cluster                  = var.create_roks_cluster
}
