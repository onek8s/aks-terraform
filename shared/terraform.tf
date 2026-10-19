terraform {
  # The environment's shared resources have a state of their own, apart from every cluster's: a
  # cluster can then be destroyed and built again without touching them.
  backend "azurerm" {
    container_name   = "tfstate"
    key              = "shared.tfstate"
    use_oidc         = true
    use_azuread_auth = true # Entra ID only: the state account allows no shared key
  }

  required_version = ">= 1.11, < 2.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.46.0, < 5.0.0"
    }
    # The agents' Claude deployment (ai_foundry): its modelProviderData is not in azurerm
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
  }
}

provider "azurerm" {
  resource_provider_registrations = "none"
  subscription_id                 = var.subscription_id

  features {}
}

# The landing zone's connectivity subscription, for the hub's side of the cells' peerings (`hub`).
# Without a hub it is the environment's subscription and does nothing.
provider "azurerm" {
  alias                           = "hub"
  resource_provider_registrations = "none"
  subscription_id                 = coalesce(local.hub_subscription_id, var.subscription_id, "00000000-0000-0000-0000-000000000000")

  features {}
}

provider "azapi" {
  subscription_id = var.subscription_id
}
