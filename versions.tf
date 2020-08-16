terraform {
  required_version = ">= 0.12"
  required_providers {
    tls = {
      source  = "hashicorp/tls"
      version = "~> 2.0.0"
    }
  }
}