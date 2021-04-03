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
      version = "2.0.0"
    }
    kustomization = {
      source  = "kbst/kustomization"
      version = "0.4.3"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.6.0"
    }
  }
}
