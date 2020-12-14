terraform {
  backend "remote" {
    organization = "axeal"

    workspaces {
      name = "tf-axeal"
    }
  }
}

provider "scaleway" {
  access_key      = var.scaleway_access_key
  secret_key      = var.scaleway_secret_key
  organization_id = var.scaleway_organization_id
  zone            = var.scaleway_zone
  region          = var.scaleway_region
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

resource "scaleway_k8s_cluster_beta" "k8s-cluster" {
  name              = var.scaleway_cluster_name
  version           = var.scaleway_k8s_version
  cni               = var.scaleway_cni
  ingress           = var.scaleway_ingress
  admission_plugins = var.scaleway_admission_plugins
}

resource "scaleway_k8s_pool_beta" "k8s-pool-0" {
  cluster_id  = scaleway_k8s_cluster_beta.k8s-cluster.id
  name        = var.scaleway_pool_name
  node_type   = var.scaleway_node_type
  size        = var.scaleway_pool_size
  min_size    = var.scaleway_pool_min_size
  max_size    = var.scaleway_pool_max_size
  autoscaling = var.scaleway_pool_autoscaling
  autohealing = var.scaleway_pool_autohealing
}

resource "scaleway_lb_ip_beta" "nginx_ingress" {}

resource "cloudflare_record" "nginx_ingress_dns" {
  zone_id = var.cloudflare_zone_id
  name    = var.cloudflare_record_name
  value   = scaleway_lb_ip_beta.nginx_ingress.ip_address
  type    = "A"
  proxied = true
}

provider "kubernetes" {
  load_config_file = "false"

  host  = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].host
  token = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].token
  cluster_ca_certificate = base64decode(
    scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].cluster_ca_certificate
  )
}

provider "kubectl" {
  load_config_file = "false"

  host  = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].host
  token = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].token
  cluster_ca_certificate = base64decode(
    scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].cluster_ca_certificate
  )
}

resource "kubernetes_namespace" "ingress-nginx" {
  metadata {
    name = "ingress-nginx"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].labels
    ]
  }
}

data "cloudflare_ip_ranges" "cloudflare" {}

resource "kubernetes_service" "ingress-nginx-controller" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
    labels = {
      "k8s.scaleway.com/cluster"                                      = split("/", scaleway_k8s_cluster_beta.k8s-cluster.id)[1]
      "k8s.scaleway.com/kapsule"                                      = ""
      "k8s.scaleway.com/managed-by-scaleway-cloud-controller-manager" = ""
    }
  }

  spec {
    type                        = "LoadBalancer"
    external_traffic_policy     = "Cluster"
    load_balancer_ip            = scaleway_lb_ip_beta.nginx_ingress.ip_address
    load_balancer_source_ranges = data.cloudflare_ip_ranges.cloudflare.ipv4_cidr_blocks

    port {
      name        = "http"
      port        = 80
      protocol    = "TCP"
      target_port = "http"
    }

    port {
      name        = "https"
      port        = 443
      protocol    = "TCP"
      target_port = "https"
    }

    selector = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
    }
  }
}

data "flux_install" "main" {
  target_path = var.flux_target_path
}

data "flux_sync" "main" {
  target_path = var.flux_target_path
  url         = "ssh://git@github.com/${var.flux_github_owner}/${var.flux_github_repo}.git"
  name        = "${var.flux_github_owner}-${var.flux_github_repo}"
  branch      = "master"
}

resource "kubernetes_namespace" "flux-system" {
  metadata {
    name = "flux-system"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].labels,
    ]
  }
}

data "kubectl_file_documents" "flux-install" {
  content = data.flux_install.main.content
}

resource "kubectl_manifest" "flux-install" {
  for_each   = { for v in data.kubectl_file_documents.flux-install.documents : sha1(v) => v }
  depends_on = [kubernetes_namespace.flux-system]

  yaml_body = each.value
}

data "kubectl_file_documents" "flux-sync" {
  content = data.flux_sync.main.content
}

resource "kubectl_manifest" "flux-sync" {
  for_each   = { for v in data.kubectl_file_documents.flux-sync.documents : sha1(v) => v }
  depends_on = [kubernetes_namespace.flux-system, kubectl_manifest.flux-install]

  yaml_body = each.value
}

resource "tls_private_key" "flux-deploy-key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

locals {
  known_hosts = "github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ=="
}

resource "kubernetes_secret" "flux-deploy-key" {
  depends_on = [kubectl_manifest.flux-install]

  metadata {
    name      = data.flux_sync.main.name
    namespace = data.flux_sync.main.namespace
  }

  data = {
    identity       = tls_private_key.flux-deploy-key.private_key_pem
    "identity.pub" = tls_private_key.flux-deploy-key.public_key_pem
    known_hosts    = local.known_hosts
  }
}

output "deploy-pub-key" {
  value = tls_private_key.flux-deploy-key.public_key_openssh
}