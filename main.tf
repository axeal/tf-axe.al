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
  version   = "~> 2.0"
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

provider "helm" {
  kubernetes {
    load_config_file = "false"

    host  = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].host
    token = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].token
    cluster_ca_certificate = base64decode(
      scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].cluster_ca_certificate
    )
  }
}

resource "kubernetes_namespace" "ingress-nginx" {
  metadata {
    name = "ingress-nginx"
  }
}

data "cloudflare_ip_ranges" "cloudflare" {}

data "kubernetes_service" "ingress-nginx-controller" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  spec {
    type                        = "LoadBalancer"
    external_traffic_policy     = "Cluster"
    load_balancer_ip            = scaleway_lb_ip_beta.nginx_ingress.ip_address
    load_balancer_source_ranges = data.cloudflare_ip_ranges.cloudflare.ipv4_cidr_blocks

    port {
      name        = http
      port        = 80
      protocol    = TCP
      target_port = http
    }

    port {
      name        = https
      port        = 443
      protocol    = TCP
      target_port = https
    }

    selector = {
      "app.kubernetes.io/component" = "controller"
      "app.kubernetes.io/instance " = "ingress-nginx"
      "app.kubernetes.io/name"      = "ingress-nginx"
    }
  }
}

resource "kubernetes_namespace" "flux" {
  metadata {
    name = "flux"
  }
}

resource "helm_release" "flux" {
  name       = "flux"
  repository = "https://charts.fluxcd.io"
  chart      = "flux"
  version    = "1.4.0"
  namespace  = "flux"

  set {
    name  = "git.url"
    value = "git@github.com:axeal/manifests"
  }

  set {
    name  = "git.path"
    value = "clusters/axe.al"
  }

  set {
    name  = "rbac.pspEnabled"
    value = "true"
  }
}

resource "helm_release" "helm-operator" {
  name       = "helm-operator"
  repository = "https://charts.fluxcd.io"
  chart      = "helm-operator"
  version    = "1.2.0"
  namespace  = "flux"

  set {
    name  = "helm.versions"
    value = "v3"
  }

  set {
    name  = "rbac.pspEnabled"
    value = "true"
  }

  set {
    name  = "git.ssh.secretName"
    value = "flux-git-deploy"
  }
}
