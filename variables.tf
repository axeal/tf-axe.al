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
    type = string
    default = "fr-par-1"
}

variable "scaleway_region" {
    type = string
    default = "fr-par"
}

variable "cloudflare_email" {
    type = string
}

variable "cloudflare_api_key" {
    type = string
}

variable "scaleway_cluster_name" {
    type = string
}

variable "scaleway_k8s_version" {
    type = string
    default = "1.18.3"
}

variable "scaleway_cni" {
    type = string
    default = "cilium"
}

variable "scaleway_ingress" {
    type = string
    default = "nginx"
}

variable "scaleway_pool_name" {
    type = string
}

variable "scaleway_node_type" {
    type = string
    default = "DEV1-M"
}

variable "scaleway_pool_size" {
    type = number
    default = 1
}

variable "cloudflare_zone_id" {
    type = string
}

variable "cloudflare_record_name" {
    type = string
}