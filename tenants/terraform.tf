terraform {
  # The environment's tenants have a state of their own, apart from every cell's and from shared/'s: a
  # tenant's onboarding plans and applies here alone, so its plan holds namespace-scoped resources and
  # nothing of a cluster, and a cell can be rebuilt without touching the tenants' definitions.
  backend "azurerm" {
    container_name   = "tfstate"
    key              = "tenants.tfstate"
    use_oidc         = true
    use_azuread_auth = true # Entra ID only: the state account allows no shared key
  }

  required_version = ">= 1.11, < 2.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.46.0, < 5.0.0"
    }
  }
}

provider "azurerm" {
  resource_provider_registrations = "none"
  subscription_id                 = var.subscription_id

  features {}
}

provider "azapi" {
  subscription_id = var.subscription_id
}
