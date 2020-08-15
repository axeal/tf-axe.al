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

data "kustomization" "ingress_nginx" {
  path = "manifests/ingress-nginx/base"
}

resource "kustomization_resource" "ingress_nginx" {
  for_each = data.kustomization.ingress_nginx.ids

  manifest = data.kustomization.ingress_nginx.manifests[each.value]
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
    name  = "controller.replicaCount"
    value = "2"
  }

  set {
    name  = "controller.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight"
    value = "100"
  }

  set {
    name  = "controller.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.labelSelector.matchExpressions[0].key"
    value = "app.kubernetes.io/name"
  }

  set {
    name  = "controller.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.labelSelector.matchExpressions[0].operator"
    value = "In"
  }

  set {
    name  = "controller.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.labelSelector.matchExpressions[0].values[0]"
    value = "ingress-nginx"
  }

  set {
    name  = "controller.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.topologyKey"    
    value = "kubernetes.io/hostname"
  }

  set {
    name  = "controller.extraArgs.default-ssl-certificate"
    value = "ingress-nginx/cloudflare-origin-ca"
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

  set {
    name  = "controller.resources.requests.cpu"
    value = "10m"
  }

  set {
    name  = "controller.resources.requests.memory"
    value = "200Mi"
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

data "kustomization" "oauth2_proxy" {
  path = "manifests/oauth2-proxy/base"
}

resource "kustomization_resource" "oauth2_proxy" {
  for_each = data.kustomization.oauth2_proxy.ids

  manifest = data.kustomization.oauth2_proxy.manifests[each.value]
}

resource "helm_release" "oauth2-proxy" {
  name       = "oauth2-proxy"
  repository = "https://kubernetes-charts.storage.googleapis.com"
  chart      = "oauth2-proxy"
  version    = var.oauth2_version
  namespace  = "oauth2-proxy"
  wait       = false

  set {
    name  = "config.clientID"
    value = var.oauth2_proxy_github_client_id
  }

  set {
    name  = "config.clientSecret"
    value = var.oauth2_proxy_github_client_secret
  }

  set {
    name  = "config.cookieSecret"
    value = var.oauth2_proxy_cookie_secret
  }

  set {
    name  = "ingress.enabled"
    value = true
  }

  set {
    name  = "ingress.hosts[0]"
    value = "auth.axe.al"
  }

  set {
    name  = "extraArgs.provider"
    value = "github"
  }

  set {
    name  = "extraArgs.whitelist-domain"
    value = ".axe.al"
  }

  set {
    name  = "extraArgs.cookie-domain"
    value = ".axe.al"
  }

  set {
    name  = "replicaCount"
    value = 2
  }

  set {
    name  = "podLabels.app\\.kubernetes\\.io/name"
    value = "oauth2-proxy"
  }

  set {
    name  = "affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight"
    value = "100"
  }

  set {
    name  = "affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.labelSelector.matchExpressions[0].key"
    value = "app.kubernetes.io/name"
  }

  set {
    name  = "affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.labelSelector.matchExpressions[0].operator"
    value = "In"
  }

  set {
    name  = "affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.labelSelector.matchExpressions[0].values[0]"
    value = "oauth2-proxy"
  }

  set {
    name  = "affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.topologyKey"
    value = "kubernetes.io/hostname"
  }

  set {
    name  = "resources.requests.cpu"
    value = "10m"
  }

  set {
    name  = "resources.requests.memory"
    value = "50Mi" 
  }

  set {
    name  = "resources.limits.cpu"
    value = "100m"
  }

  set {
    name  = "resources.limits.memory"
    value = "100Mi"
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

  set {
    name  = "prometheus.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-url"
    value = "https://${var.auth_prefix}.${var.cloudflare_record_name}/oauth2/auth"
    type  = "string"
  }

  set {
    name  = "prometheus.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-signin"
    value = "https://${var.auth_prefix}.${var.cloudflare_record_name}/oauth2/start?rd=https://$host$escaped_request_uri"
  }

  set {
    name  = "prometheus.ingress.hosts[0]"
    value = "prometheus.axe.al"
  }

  set {
    name  = "grafana.ingress.enabled"
    value = "true"
  }

  set {
    name  = "grafana.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-url"
    value = "https://${var.auth_prefix}.${var.cloudflare_record_name}/oauth2/auth"
    type  = "string"
  }

  set {
    name  = "grafana.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-signin"
    value = "https://${var.auth_prefix}.${var.cloudflare_record_name}/oauth2/start?rd=https://$host$escaped_request_uri"
    type  = "string"
  }

  set {
    name  = "grafana.ingress.hosts[0]"
    value = "grafana.axe.al"
  }

  set {
    name  = "alertmanager.ingress.enabled"
    value = "true"
  }

  set {
    name  = "alertmanager.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-url"
    value = "https://${var.auth_prefix}.${var.cloudflare_record_name}/oauth2/auth"
    type  = "string"
  }

  set {
    name  = "alertmanager.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-signin"
    value = "https://${var.auth_prefix}.${var.cloudflare_record_name}/oauth2/start?rd=https://$host$escaped_request_uri"
    type  = "string"
  }

  set {
    name  = "alertmanager.ingress.hosts[0]"
    value = "alerts.axe.al"
  }

  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]"
    value = "ReadWriteOnce"
  }

  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"
    value = "25Gi"
  }

  set {
    name  = "prometheus.prometheusSpec.retentionSize"
    value = "25GiB"
  }

  set {
    name  = "prometheus.prometheusSpec.resources.requests.cpu"
    value = "1000m"
  }

  set {
    name  = "prometheus.prometheusSpec.resources.requests.memory"
    value = "2Gi"
  }

  set {
    name  = "grafana.additionalDataSources[0].name"
    value = "Loki"
  }

  set {
    name  = "grafana.additionalDataSources[0].type"
    value = "loki"
  }

  set {
    name  = "grafana.additionalDataSources[0].access"
    value = "proxy"
  }

  set {
    name  = "grafana.additionalDataSources[0].url"
    value = "http://loki:3100"
  }

  set {
    name  = "grafana.additionalDataSources[0].editable"
    value = "false"
  }

  set {
    name  = "grafana.additionalDataSources[0].basicAuth"
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

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/loki/charts"
  chart      = "loki"
  version    = var.loki_version
  namespace  = "prometheus"
  wait       = false

  set {
    name  = "serviceMonitor.enabled"
    value = true
  }

  set {
    name  = "persistence.enabled"
    value = true
  }

  set {
    name  = "config.chunk_store_config.max_look_back_period"
    value = "720h"
  }

  set {
    name  = "config.table_manager.retention_deletes_enabled"
    value = true
  }

  set {
    name  = "config.table_manager.retention_period"
    value = "720h"
  }

}

resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/loki/charts"
  chart      = "promtail"
  version    = var.promtail_version
  namespace  = "prometheus"
  wait       = false

  set {
    name  = "loki.serviceName"
    value = "loki"
  }

  set {
    name  = "serviceMonitor.enabled"
    value = true
  }

  set {
    name  = "extraScrapeConfigs[0].job_name"
    value = "journal"
  }

  set {
    name  = "extraScrapeConfigs[0].journal.path"
    value = "/var/log/journal"
  }

  set {
    name  = "extraScrapeConfigs[0].journal.max_age"
    value = "12h"
  }

  set {
    name  = "extraScrapeConfigs[0].journal.labels.job"
    value = "systemd-journal"
  }

  set {
    name  = "extraScrapeConfigs[0].relabel_configs[0].source_labels[0]"
    value = "__journal__systemd_unit"
  }

  set {
    name  = "extraScrapeConfigs[0].relabel_configs[0].target_label"
    value = "unit"
  }

  set {
    name  = "extraScrapeConfigs[0].relabel_configs[1].source_labels[0]"
    value = "__journal__hostname"
  }

  set {
    name  = "extraScrapeConfigs[0].relabel_configs[1].target_label"
    value = "hostname"
  }

  set {
    name  = "extraVolumes[0].name"
    value = "journal"
  }

  set {
    name  = "extraVolumes[0].hostPath.path"
    value = "/var/log/journal"
  }

  set {
    name  = "extraVolumeMounts[0].name"
    value = "journal"
  }

  set {
    name  = "extraVolumeMounts[0].mountPath"
    value = "/var/log/journal"
  }

  set {
    name  = "extraVolumeMounts[0].readOnly"
    value = true
  }
}