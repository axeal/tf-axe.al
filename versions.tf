terraform {
  required_version = ">= 0.13"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "2.14.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "1.13.3"
    }
    scaleway = {
      source  = "scaleway/scaleway"
      version = "1.17.2"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "0.0.6"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.9.4"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "3.0.0"
    }
  }
}