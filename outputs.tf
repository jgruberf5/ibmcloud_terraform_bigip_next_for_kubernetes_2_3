# ============================================================
# Outputs — F5 BIG-IP Next for Kubernetes 2.3
# ============================================================


# ============================================================
# roks_cluster
# ============================================================

output "roks_cluster_name" {
  description = "Name of the ROKS cluster"
  value       = module.roks_cluster.roks_cluster_name
}

output "roks_transit_gateway_name" {
  description = "Name of the Transit Gateway"
  value       = module.roks_cluster.transit_gateway_name
}


# ============================================================
# flo outputs (also wired into cne_instance)
# ============================================================

output "flo_namespace" {
  description = "Kubernetes namespace where the F5 Lifecycle Operator is installed"
  value       = local.flo_namespace
}

output "flo_trusted_profile_id" {
  description = "IBM Cloud Trusted Profile ID created by FLO for cluster authentication"
  value       = local.flo_trusted_profile_id
}

output "flo_cluster_issuer_name" {
  description = "Kubernetes ClusterIssuer name created by FLO for certificate management"
  value       = local.flo_cluster_issuer_name
}

output "cneinstance_network_attachments" {
  description = "Network attachment names used by the CNEInstance"
  value       = local.cneinstance_network_attachments
}


# ============================================================
# testing
# ============================================================

output "testing_tgw_jumphost_ip" {
  description = "Public IP of the TGW-connected jumphost (empty when testing_create_tgw_jumphost = false)"
  value       = try(module.testing.testing_tgw_jumphost_public_ip, "")
}

output "testing_cluster_jumphost_ips" {
  description = "Public IPs of the per-zone cluster jumphosts (empty when testing_create_cluster_jumphosts = false)"
  value       = try(module.testing.testing_cluster_jumphost_public_ips, [])
}
