terraform {
  required_version = ">= 0.13"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "2.19.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.0.3"
    }
    scaleway = {
      source  = "scaleway/scaleway"
      version = "2.0.0"
    }
    kustomization = {
      source  = "kbst/kustomization"
      version = "0.4.3"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.7.0"
    }
  }
}
