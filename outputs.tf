# ============================================================
# Outputs
# F5 BIG-IP Next for Kubernetes 2.3 — Direct Terraform Project
# ============================================================


# ============================================================
# WS1 — ROKS Cluster
# ============================================================

output "roks_cluster_name" {
  description = "Name of the ROKS cluster (ws1 output or supplied roks_cluster_id_or_name)"
  value       = local.ws1_roks_cluster_name
}

output "roks_transit_gateway_name" {
  description = "Name of the Transit Gateway (ws1 output or roks_transit_gateway_name variable)"
  value       = local.ws1_transit_gateway_name
}


# ============================================================
# WS3 — FLO outputs wired into WS4
# ============================================================

output "flo_namespace" {
  description = "Kubernetes namespace where the F5 Lifecycle Operator is installed"
  value       = local.ws3_flo_namespace
}

output "flo_trusted_profile_id" {
  description = "IBM Cloud Trusted Profile ID created by FLO for cluster authentication"
  value       = local.ws3_flo_trusted_profile_id
}

output "flo_cluster_issuer_name" {
  description = "Kubernetes ClusterIssuer name created by FLO for certificate management"
  value       = local.ws3_flo_cluster_issuer_name
}

output "cneinstance_network_attachments" {
  description = "Network attachment names used by the CNEInstance"
  value       = local.ws3_cneinstance_network_attachments
}


# ============================================================
# WS6 — Testing Jumphosts
# ============================================================

output "testing_tgw_jumphost_ip" {
  description = "Public IP of the TGW-connected jumphost (empty when testing_create_tgw_jumphost = false)"
  value       = try(module.ws6_testing.testing_tgw_jumphost_ip, "")
}

output "testing_cluster_jumphost_ips" {
  description = "Public IPs of the per-zone cluster jumphosts (empty when testing_create_cluster_jumphosts = false)"
  value       = try(module.ws6_testing.testing_cluster_jumphost_ips, [])
}
