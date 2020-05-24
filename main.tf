provider "scaleway" {
  access_key      = var.scaleway_access_key
  secret_key      = var.scaleway_secret_key
  organization_id = var.scaleway_organization_id
  zone            = var.scaleway_zone
  region          = var.scaleway_region
}

provider "cloudflare" {
  version = "~> 2.0"
  email   = var.cloudflare_email
  api_key = var.cloudflare_api_key
}

resource "scaleway_k8s_cluster_beta" "k8s-cluster" {
  name = var.scaleway_cluster_name
  version = var.scaleway_k8s_version
  cni = var.scaleway_cni
  ingress = var.scaleway_ingress
}

resource "scaleway_k8s_pool_beta" "k8s-pool-0" {
  cluster_id = scaleway_k8s_cluster_beta.k8s-pool-0.id
  name = var.scaleway_pool_name
  node_type = var.scaleway_node_type
  size = var.scaleway_pool_size
}

resource "cloudflare_record" "cluster-dns" {
  zone_id = var.cloudflare_zone_id
  name    = var.cloudflare_record_name
  value   = scaleway_k8s_cluster_beta.k8s-pool-0.nodes[0].public_ip
  type    = "A"
  proxied = true
}
