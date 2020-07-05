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
  version              = "~> 2.0"
  api_token            = var.cloudflare_api_token
  api_user_service_key = var.cloudflare_api_user_service_key
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

resource "kubernetes_namespace" "ingress-nginx" {
  metadata {
    name = "ingress-nginx"
  }
}

resource "tls_private_key" "cloudflare_origin_ca" {
  algorithm = var.cloudflare_origin_ca_key_algorithm
}

resource "tls_cert_request" "cloudflare_origin_ca" {
  key_algorithm   = tls_private_key.cloudflare_origin_ca.algorithm
  private_key_pem = tls_private_key.cloudflare_origin_ca.private_key_pem

  subject {
    common_name  = ""
    organization = "Terraform"
  }
}

resource "cloudflare_origin_ca_certificate" "cloudflare_origin_ca" {
  csr                = tls_cert_request.cloudflare_origin_ca.cert_request_pem
  hostnames          = var.cloudflare_origin_ca_hostnames
  request_type       = "origin-rsa"
  requested_validity = 365
}

resource "kubernetes_secret" "cloudflare_origin_ca" {
  metadata {
    name      = "cloudflare-origin-ca"
    namespace = "ingress-nginx"
  }

  data = {
    "tls.crt" = cloudflare_origin_ca_certificate.cloudflare_origin_ca.certificate
    "tls.key" = tls_private_key.cloudflare_origin_ca.private_key_pem
  }

  type = "kubernetes.io/tls"
}

data "cloudflare_ip_ranges" "cloudflare" {}

resource "helm_release" "ingress-nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_nginx_version
  namespace  = "ingress-nginx"

  set {
    name  = "controller.service.loadBalancerIP"
    value = scaleway_lb_ip_beta.nginx_ingress.ip_address
  }

  dynamic "set" {
    for_each = data.cloudflare_ip_ranges.cloudflare.ipv4_cidr_blocks

    content {
      name  = "controller.service.loadBalancerSourceRanges[${set.key}]"
      value = set.value
    }
  }

  set {
    name  = "controller.kind"
    value = "DaemonSet"
  }

  set {
    name  = "controller.extraArgs.default-ssl-certificate"
    value = "ingress-nginx/cloudflare-origin-ca"
  }

  set {
    name  = "controller.daemonset.useHostPort"
    value = "false"
  }

  set {
    name  = "controller.metrics.enabled"
    value = "true"
  }

  set {
    name  = "controller.metrics.serviceMonitor.enabled"
    value = "true"
  }

  set {
    name  = "controller.metrics.serviceMonitor.namespace"
    value = "prometheus"
  }

  set {
    name  = "podSecurityPolicy.enabled"
    value = "true"
  }

}

data "kustomization" "psps" {
  path = "manifests/psp"
}

resource "kustomization_resource" "psps" {
  for_each = data.kustomization.psps.ids

  manifest = data.kustomization.psps.manifests[each.value]
}

resource "kubernetes_namespace" "oauth2_proxy" {
  metadata {
    name = "oauth2-proxy"
  }
}

resource "kubernetes_secret" "oauth2_proxy" {
  metadata {
    name      = "oauth-proxy-secret"
    namespace = "oauth2-proxy"
  }

  data = {
    github-client-id     = var.oauth2_proxy_github_client_id
    github-client-secret = var.oauth2_proxy_github_client_secret
    cookie-secret        = var.oauth2_proxy_cookie_secret
  }
}

data "kustomization" "oauth2_proxy" {
  path = "manifests/oauth2-proxy/base"
}

resource "kustomization_resource" "oauth2_proxy" {
  for_each = data.kustomization.oauth2_proxy.ids

  manifest = data.kustomization.oauth2_proxy.manifests[each.value]
}

resource "kubernetes_ingress" "oauth2_proxy_ingress" {
  metadata {
    name      = "oauth2-proxy"
    namespace = "oauth2-proxy"
  }

  spec {
    rule {
      host = "auth.axe.al"
      http {
        path {
          backend {
            service_name = "oauth2-proxy"
            service_port = 4180
          }
          path = "/oauth2"
        }
      }
    }
    tls {
      hosts = ["auth.axe.al"]
    }
  }
}

resource "kubernetes_namespace" "prometheus" {
  metadata {
    name = "prometheus"
  }
}

data "kustomization" "prometheus" {
  path = "manifests/prometheus/base"
}

resource "kustomization_resource" "prometheus" {
  for_each = data.kustomization.prometheus.ids

  manifest = data.kustomization.prometheus.manifests[each.value]
}

resource "helm_release" "prometheus-operator" {
  name       = "prometheus-operator"
  repository = "https://kubernetes-charts.storage.googleapis.com"
  chart      = "prometheus-operator"
  version    = var.prometheus_operator_version
  namespace  = "prometheus"
  wait       = false

  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

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

  set {
    name  = "prometheus.ingress.enabled"
    value = "true"
  }

  set_string {
    name  = "prometheus.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-url"
    value = "https://${var.auth_prefix}.${var.cloudflare_record_name}/oauth2/auth"
  }

  set_string {
    name  = "prometheus.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-signin"
    value = "https://${var.auth_prefix}.${var.cloudflare_record_name}/oauth2/start?rd=https://$host$escaped_request_uri"
  }

  set {
    name  = "prometheus.ingress.hosts[0]"
    value = var.cloudflare_record_name
  }

  set {
    name  = "prometheus.ingress.paths[0]"
    value = "/prometheus/"
  }

  set {
    name  = "prometheus.prometheusSpec.externalUrl"
    value = "https://axe.al/prometheus/"
  }

  set {
    name  = "prometheus.ingress.tls[0].hosts[0]"
    value = "axe.al"
  }

  set_string {
    name  = "grafana.grafana\\.ini.server.root_url"
    value = "https://${var.cloudflare_record_name}/grafana"
  }

  set_string {
    name  = "grafana.grafana\\.ini.server.serve_from_sub_path"
    value = "true"
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

resource "kubernetes_namespace" "blog" {
  metadata {
    name = "blog"
  }
}

data "kustomization" "blog" {
  path = "manifests/blog/base"
}

resource "kustomization_resource" "blog" {
  for_each = data.kustomization.blog.ids

  manifest = data.kustomization.blog.manifests[each.value]
}

resource "kubernetes_ingress" "blog_ingress" {
  metadata {
    name      = "blog"
    namespace = "blog"
  }

  spec {
    rule {
      host = "axe.al"
      http {
        path {
          backend {
            service_name = "blog"
            service_port = 8080
          }
        }
      }
    }
  }
}