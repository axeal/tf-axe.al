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

# Need to wait for DNS propagation of Kubernetes API endpoint record
resource "time_sleep" "wait_60_seconds" {
  depends_on = [scaleway_k8s_cluster_beta.k8s-cluster]

  create_duration = "60s"
}

provider "kustomization" {
  kubeconfig_raw = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].config_file
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

  depends_on = [time_sleep.wait_60_seconds, scaleway_k8s_pool_beta.k8s-pool-0]
}

data "cloudflare_ip_ranges" "cloudflare" {}

resource "kubernetes_service" "ingress-nginx-controller" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = kubernetes_namespace.ingress-nginx.metadata[0].name
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

data "kustomization_build" "sealed-secrets" {
  path = "sealed-secrets"
}

resource "kustomization_resource" "sealed-secrets" {
  for_each = data.kustomization_build.sealed-secrets.ids

  manifest = data.kustomization_build.sealed-secrets.manifests[each.value]

  depends_on = [time_sleep.wait_60_seconds, scaleway_k8s_pool_beta.k8s-pool-0]
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

  depends_on = [time_sleep.wait_60_seconds, scaleway_k8s_pool_beta.k8s-pool-0]
}

resource "kubernetes_secret" "sops-gpg" {
  metadata {
    name      = "sops-gpg"
    namespace = kubernetes_namespace.flux-system.metadata[0].name
  }

  data = {
    "sops.asc" = var.gpg_key
  }
}

data "kustomization_build" "flux" {
  path = "flux/install"
}

resource "kustomization_resource" "flux" {
  for_each = data.kustomization_build.flux.ids

  manifest = data.kustomization_build.flux.manifests[each.value]

  depends_on = [kubernetes_namespace.flux-system]
}

data "kustomization_build" "flux-sync" {
  path = "flux-sync"
}

resource "kustomization_resource" "flux-sync" {
  for_each = data.kustomization_build.flux-sync.ids

  manifest = data.kustomization_build.flux-sync.manifests[each.value]

  depends_on = [kubernetes_namespace.flux-system, kustomization_resource.flux]
}

