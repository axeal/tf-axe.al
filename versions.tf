terraform {
  required_version = ">= 0.12"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "2.9.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "1.2.4"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "1.12.0"
    }
    scaleway = {
      source  = "scaleway/scaleway"
      version = "1.16.0"
    }
  }
}