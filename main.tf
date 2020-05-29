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
  version = "~> 2.0"
  email   = var.cloudflare_email
  api_key = var.cloudflare_api_key
}

resource "scaleway_k8s_cluster_beta" "k8s-cluster" {
  name              = var.scaleway_cluster_name
  version           = var.scaleway_k8s_version
  cni               = var.scaleway_cni
  ingress           = var.scaleway_ingress
  admission_plugins = var.scaleway_admission_plugins
}

resource "scaleway_k8s_pool_beta" "k8s-pool-0" {
  cluster_id = scaleway_k8s_cluster_beta.k8s-cluster.id
  name       = var.scaleway_pool_name
  node_type  = var.scaleway_node_type
  size       = var.scaleway_pool_size
}

provider "kubernetes" {
  load_config_file = "false"

  host  = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].host
  token = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].token
  cluster_ca_certificate = base64decode(
    scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].cluster_ca_certificate
  )
}

resource "kubernetes_namespace" "blog" {
  metadata {
    name = "blog"
  }
}


resource "kubernetes_secret" "blog-cloudflare-origin" {
  metadata {
    name      = "blog-tls"
    namespace = "blog"
  }

  data = {
    "tls.crt" = var.cloudflare_origin_cert
    "tls.key" = var.cloudflare_origin_key
  }

  type = "kubernetes.io/tls"
}

provider "kustomization" {
  kubeconfig_raw = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].config_file
}

data "kustomization" "blog" {
  path = "manifests/blog/base"
}

resource "kustomization_resource" "blog" {
  for_each = data.kustomization.blog.ids

  manifest = data.kustomization.blog.manifests[each.value]
}

provider "helm" {
  load_config_file = "false"

  host  = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].host
  token = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].token
  cluster_ca_certificate = base64decode(
    scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].cluster_ca_certificate
  )
}

resource "helm_release" "prometheus-operator" {
  name  = "prometheus-operator"
  chart = "stable/prometheus-operator"
}