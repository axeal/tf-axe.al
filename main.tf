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
  cluster_id = scaleway_k8s_cluster_beta.k8s-cluster.id
  name = var.scaleway_pool_name
  node_type = var.scaleway_node_type
  size = var.scaleway_pool_size
}

provider "kubernetes" {
  load_config_file = "false"

  host  = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].host
  token  = scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].token
  cluster_ca_certificate = base64decode(
    scaleway_k8s_cluster_beta.k8s-cluster.kubeconfig[0].cluster_ca_certificate
  )
}

resource "kubernetes_namespace" "blog" {
    name = "blog"
}

resource "kubernetes_service_account" "blog-deployment-sa" {
    metadata {
        name      = "blog-deployment-sa"
        namespace = "blog"
    }
}

resource "kubernetes_role" "blog-deployment-role" {
    metadata {
        name      = "blog-deployment-role"
        namespace = "blog"
    }

    rule {
        api_groups      = ["apps"]
        resources       = ["deployments"]
        verbs           = ["get", "create", "update", "delete"]
        resource_names  = ["blog"]
    }
}

resource "kubernetes_role_binding" "blog-deployment-rolebinding" {
    metadata {
        name      = "blog-deployment-rolebinding"
        namespace = "blog"
    }
    role_ref {
        api_group = "rbac.authorization.k8s.io"
        kind      = "Role"
        name      = "blog-deployment-role"
    }
    subject {
        kind      = "ServiceAccount"
        name      = "blog-deployment-sa"
        namespace = "blog-deployment"
    }
}

resource "kubernetes_deployment" "blog" {
    metadata {
        namespace = "blog"
        name      = "blog"
        labels = {
            app = "blog"
        }
    }

    spec {
        replicas = 1

        selector {
            match_labels = {
                app = "blog"
            }
        }

        template {
            metadata {
                labels = {
                    app = "blog"
                }
            }

            spec {
                container {
                    image = "axeal/axe.al:latest"
                    name = "axeal"
                    port {
                        container_port = 80
                        protocol = "TCP"
                    }
                }
            }
        }
    }
}

resource "kubernetes_secret" "blog-cloudflare-origin" {
    metadata {
        name = "axeal-tls"
    }

    data = {
        "tls.cert" = var.cloudflare_origin_cert
        "tls.key"  = var.cloudflare_origin_key
    }

    type = "kubernetes.io/tls"
}

resource "kubernetes_service" "blog" {
    metadata {
        name      = "blog"
        namespace = "blog"
    }
    spec {
        selector = {
            app: "blog"
        }
        port {
            port        = 80
            target_port = 80
            protocol    = "TCP"
        }
    }
}

resource "kubernetes_ingress" "blog" {
    metadata {
        namespace = "blog"
        name      = "blog"
    }

    spec {
        tls {
            hosts = ["axe.al"]
            secret_name = "axeal-tls"
        }
        rule {
            host = "axe.al"
            http {
                path {
                    backend {
                        service_name = "blog"
                        service_port = 80
                    }
                }
            }
        }
    }
}