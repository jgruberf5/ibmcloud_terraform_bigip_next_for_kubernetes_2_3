# ============================================================
# License Module
# ============================================================
# Deploys the F5 BNK License Custom Resource
# Must be deployed after CNEInstance/FLO to ensure the License CRD exists

locals {
  global_enabled = var.enabled
  jwt_token = local.global_enabled && var.use_cos_bucket ? trimspace(data.http.jwt_download[0].response_body) : var.jwt_token
}

# Wait for License CRD to be available (also gates on cneinstance completion)
resource "time_sleep" "wait_for_license_crd" {
  count           = var.enabled ? 1 : 0
  create_duration = "10s"
  triggers = {
    cneinstance_dependency = var.cneinstance_dependency != null ? tostring(var.cneinstance_dependency) : "direct-apply"
  }
}

# ==============================================================================
# COS Bucket Resources (when use_cos_bucket = true)
# ==============================================================================

data "ibm_resource_groups" "all_resource_groups" {
  count = local.global_enabled && var.use_cos_bucket ? 1 : 0
}

data "ibm_resource_group" "resource_group" {
  count = local.global_enabled && var.use_cos_bucket ? 1 : 0
  name  = var.ibmcloud_resource_group != "" ? var.ibmcloud_resource_group : [
    for rg in data.ibm_resource_groups.all_resource_groups[0].resource_groups :
    rg.name if rg.is_default == true
  ][0]
}

data "ibm_resource_instance" "cos_instance" {
  count             = local.global_enabled && var.use_cos_bucket ? 1 : 0
  name              = var.ibmcloud_cos_instance_name
  resource_group_id = data.ibm_resource_group.resource_group[0].id
  service           = "cloud-object-storage"
}

data "ibm_cos_bucket" "cos_bucket" {
  count                = local.global_enabled && var.use_cos_bucket ? 1 : 0
  bucket_name          = var.ibmcloud_resources_cos_bucket
  resource_instance_id = data.ibm_resource_instance.cos_instance[0].id
  bucket_region        = var.ibmcloud_cos_bucket_region
  bucket_type          = "region_location"
}

data "ibm_cos_bucket_object" "f5_cne_subscription_jwt_object" {
  count           = local.global_enabled && var.use_cos_bucket ? 1 : 0
  bucket_crn      = data.ibm_cos_bucket.cos_bucket[0].crn
  bucket_location = data.ibm_cos_bucket.cos_bucket[0].bucket_region
  key             = var.f5_cne_subscription_jwt_file
}

# Fetch a short-lived IAM bearer token to authenticate the COS S3 REST request
data "http" "iam_token" {
  count  = local.global_enabled && var.use_cos_bucket ? 1 : 0
  url    = "https://iam.cloud.ibm.com/identity/token"
  method = "POST"
  request_headers = {
    "Content-Type" = "application/x-www-form-urlencoded"
  }
  request_body = "grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey&apikey=${var.ibmcloud_api_key}"
}

# Download JWT file via COS S3-compatible REST API (body field may be empty for binary content_type)
data "http" "jwt_download" {
  count  = local.global_enabled && var.use_cos_bucket ? 1 : 0
  url    = "https://s3.${var.ibmcloud_cos_bucket_region}.cloud-object-storage.appdomain.cloud/${var.ibmcloud_resources_cos_bucket}/${var.f5_cne_subscription_jwt_file}"
  method = "GET"
  request_headers = {
    "Authorization"           = "Bearer ${jsondecode(data.http.iam_token[0].response_body).access_token}"
    "ibm-service-instance-id" = data.ibm_resource_instance.cos_instance[0].guid
  }
}

# Create License CR in utils namespace via curl Server-Side Apply
resource "null_resource" "bnk_license" {
  count = var.enabled ? 1 : 0

  triggers = {
    jwt             = local.jwt_token
    license_mode    = var.license_mode
    kube_host       = var.kube_host
    token           = var.kube_token
    utils_namespace = var.utils_namespace
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -sf -X PATCH \
        -H "Authorization: Bearer ${var.kube_token}" \
        -H "Content-Type: application/apply-patch+yaml" \
        -k "${var.kube_host}/apis/k8s.f5net.com/v1/namespaces/${var.utils_namespace}/licenses/bnk-license?fieldManager=terraform&force=true" \
        -d '{"apiVersion":"k8s.f5net.com/v1","kind":"License","metadata":{"name":"bnk-license","namespace":"${var.utils_namespace}"},"spec":{"jwt":"${local.jwt_token}","operationMode":"${var.license_mode}"}}'
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      curl -sk -X DELETE \
        -H "Authorization: Bearer ${self.triggers.token}" \
        "${self.triggers.kube_host}/apis/k8s.f5net.com/v1/namespaces/${self.triggers.utils_namespace}/licenses/bnk-license" || true
    EOT
  }

  depends_on = [time_sleep.wait_for_license_crd[0]]
}
