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

data "kustomization" "psps" {
  path = "manifests/psp"
}

resource "kustomization_resource" "psps" {
  for_each = data.kustomization.psps.ids

  manifest = data.kustomization.psps.manifests[each.value]
}

data "kustomization" "blog" {
  path = "manifests/blog/base"
}

resource "kustomization_resource" "blog" {
  for_each = data.kustomization.blog.ids

  manifest = data.kustomization.blog.manifests[each.value]
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

resource "kubernetes_namespace" "prometheus" {
  metadata {
    name = "prometheus"
  }
}

resource "helm_release" "prometheus-operator" {
  name       = "prometheus-operator"
  repository = "https://kubernetes-charts.storage.googleapis.com"
  chart      = "prometheus-operator"
  version    = var.prometheus_operator_version
  namespace  = "prometheus"
  wait       = false

  set {
    name  = "kubeEtcd.enabled"
    value = "false"
  }

  set {
    name  = "kubeProxy.enabled"
    value = "false"
  }

  set {
    name  = "kubeScheduler.enabled"
    value = "false"
  }

  set {
    name  = "kubeControllerManager.enabled"
    value = "false"
  }
}

resource "kubernetes_namespace" "elastic" {
  metadata {
    name = "elastic"
  }
}

data "kustomization" "elasticsearch" {
  path = "manifests/elastic/base"
}

resource "kustomization_resource" "elasticsearch" {
  for_each = data.kustomization.elasticsearch.ids

  manifest = data.kustomization.elasticsearch.manifests[each.value]
}

resource "helm_release" "elasticsearch" {
  name       = "elasticsearch"
  repository = "https://helm.elastic.co"
  chart      = "elasticsearch"
  version    = var.elastic_version
  namespace  = "elastic"
  wait       = false

  set {
    name  = "replicas"
    value = var.elasicsearch_replicas
  }

  set {
    name  = "minimumMasterNodes"
    value = var.elasticsearch_minimum_master_nodes
  }
}

resource "helm_release" "logstash" {
  name       = "logstash"
  repository = "https://helm.elastic.co"
  chart      = "logstash"
  version    = var.elastic_version
  namespace  = "elastic"
  wait       = false

  set {
    name  = "service.type"
    value = "ClusterIP"
  }

  set {
    name  = "service.ports[0].name"
    value = "beats"
  }

  set {
    name  = "service.ports[0].port"
    value = "5044"
  }

  set {
    name  = "service.ports[0].protocol"
    value = "TCP"
  }

  set {
    name  = "service.ports[0].targetPort"
    value = "50444"
  }

  set {
    name  = "service.ports[1].name"
    value = "http"
  }

  set {
    name  = "service.ports[1].port"
    value = "8080"
  }

  set {
    name  = "service.ports[1].protocol"
    value = "TCP"
  }

  set {
    name  = "service.ports[1].targetPort"
    value = "8080"
  }
}

resource "helm_release" "filebeat" {
  name       = "filebeat"
  repository = "https://helm.elastic.co"
  chart      = "filebeat"
  version    = var.elastic_version
  namespace  = "elastic"
  wait       = false
}

resource "helm_release" "kibana" {
  name       = "kibana"
  repository = "https://helm.elastic.co"
  chart      = "kibana"
  version    = var.elastic_version
  namespace  = "elastic"
  wait       = false
}

resource "helm_release" "fluentd" {
  name       = "fluentd"
  repository = "https://kubernetes-charts.storage.googleapis.com"
  chart      = "fluentd"
  version    = var.fluentd_version
  namespace  = "elastic"
  wait       = false

  set {
    name  = "output.port"
    value = "elasticsearch-master.elastic.svc.cluster.local"
  }
}