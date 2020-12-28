variable "scaleway_access_key" {
  type = string
}

variable "scaleway_secret_key" {
  type = string
}

variable "scaleway_organization_id" {
  type = string
}

variable "scaleway_zone" {
  type    = string
  default = "fr-par-1"
}

variable "scaleway_region" {
  type    = string
  default = "fr-par"
}

variable "cloudflare_api_token" {
  type = string
}

variable "scaleway_cluster_name" {
  type = string
}

variable "scaleway_k8s_version" {
  type    = string
  default = "1.18.8"
}

variable "scaleway_cni" {
  type    = string
  default = "cilium"
}

variable "scaleway_ingress" {
  type    = string
  default = "none"
}

variable "scaleway_admission_plugins" {
  type    = list(string)
  default = []
}

variable "scaleway_pool_name" {
  type = string
}

variable "scaleway_node_type" {
  type    = string
  default = "DEV1-M"
}

variable "scaleway_pool_size" {
  type    = number
  default = 1
}

variable "scaleway_pool_min_size" {
  type    = number
  default = 1
}

variable "scaleway_pool_max_size" {
  type    = number
  default = 5
}

variable "scaleway_pool_autoscaling" {
  type    = bool
  default = true
}

variable "scaleway_pool_autohealing" {
  type    = bool
  default = true
}

variable "cloudflare_zone_id" {
  type = string
}

variable "cloudflare_record_name" {
  type = string
}

variable "flux_target_path" {
  type = string
}

variable "flux_github_owner" {
  type = string
}

variable "flux_github_repo" {
  type = string
}

variable "gpg_key" {
  type = string
}
