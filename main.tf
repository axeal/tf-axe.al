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
  cluster_id = scaleway_k8s_cluster_beta.k8s-cluster.id
  name       = var.scaleway_pool_name
  node_type  = var.scaleway_node_type
  size       = var.scaleway_pool_size
}

resource "scaleway_lb_ip_beta" "nginx_ingress" {
}

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

provider "kustomization" {
  kubeconfig_raw = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].config_file
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

resource "kubernetes_service" "nginx_ingress_loadbalancer" {
  metadata {
    name      = "nginx-ingress"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"    = "nginx-ingress"
      "app.kubernetes.io/part-of" = "nginx-ingress"
      "k8s.scaleway.com/cluster"  = split("/",scaleway_k8s_cluster_beta.k8s-cluster.id)[1]
      "k8s.scaleway.com/kapsule"  = ""
    }
  }
  spec {
    selector = {
      "app.kubernetes.io/name"    = "nginx-ingress"
      "app.kubernetes.io/part-of" = "nginx-ingress"
    }
    session_affinity = "ClientIP"
    port {
      port        = 80
      target_port = 80
      name        = "http"
    }
    port {
      port        = 443
      target_port = 443
      name        = "https"
    }

    type             = "LoadBalancer"
    load_balancer_ip = scaleway_lb_ip_beta.nginx_ingress.ip_address
  }
}

data "kustomization" "psps" {
  path = "manifests/psp"
}

resource "kustomization_resource" "psps" {
  for_each = data.kustomization.psps.ids

  manifest = data.kustomization.psps.manifests[each.value]
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

resource "tls_private_key" "vpa_webhook_ca" {
  algorithm = var.vpa_webhook_ca_key_algorithm
}

resource "tls_self_signed_cert" "vpa_webhook_ca" {
  key_algorithm   = tls_private_key.vpa_webhook_ca.algorithm
  private_key_pem = tls_private_key.vpa_webhook_ca.private_key_pem

  subject {
    common_name = "vpa_webhook_ca"
  }

  validity_period_hours = var.vpa_webhook_ca_cert_validity_period
  is_ca_certificate     = true

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
    "cert_signing"
  ]
}

resource "tls_private_key" "vpa_webhook_server" {
  algorithm = var.vpa_webhook_server_key_algorithm
}

resource "tls_cert_request" "vpa_webhook_server" {
  key_algorithm   = tls_private_key.vpa_webhook_server.algorithm
  private_key_pem = tls_private_key.vpa_webhook_server.private_key_pem

  subject {
    common_name = "vpa-webhook.kube-system.svc"
  }
}

resource "tls_locally_signed_cert" "vpa_webhook_server" {
  cert_request_pem = tls_cert_request.vpa_webhook_server.cert_request_pem

  ca_key_algorithm   = tls_private_key.vpa_webhook_ca.algorithm
  ca_private_key_pem = tls_private_key.vpa_webhook_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.vpa_webhook_ca.cert_pem

  validity_period_hours = var.vpa_webhook_server_cert_validity_period

  allowed_uses = [
    "content_commitment",
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth"
  ]
}

resource "kubernetes_secret" "vpa-tls-certs" {
  metadata {
    name      = "vpa-tls-certs"
    namespace = "kube-system"
  }

  data = {
    "caKey.pem"      = tls_private_key.vpa_webhook_ca.private_key_pem
    "caCert.pem"     = tls_self_signed_cert.vpa_webhook_ca.cert_pem
    "serverKey.pem"  = tls_private_key.vpa_webhook_server.private_key_pem
    "serverCert.pem" = tls_locally_signed_cert.vpa_webhook_server.cert_pem
  }

  type = "Opaque"
}

data "kustomization" "vpa" {
  path = "manifests/vpa/base"
}

resource "kustomization_resource" "vpa" {
  for_each = data.kustomization.vpa.ids

  manifest = data.kustomization.vpa.manifests[each.value]
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

resource "helm_release" "kibana" {
  name       = "kibana"
  repository = "https://helm.elastic.co"
  chart      = "kibana"
  version    = var.elastic_version
  namespace  = "elastic"
  wait       = false
}

data "kustomization" "fluentd" {
  path = "manifests/fluentd/base"
}

resource "kustomization_resource" "fluentd" {
  for_each = data.kustomization.fluentd.ids

  manifest = data.kustomization.fluentd.manifests[each.value]
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

data "kustomization" "blog" {
  path = "manifests/blog/base"
}

resource "kustomization_resource" "blog" {
  for_each = data.kustomization.blog.ids

  manifest = data.kustomization.blog.manifests[each.value]
}