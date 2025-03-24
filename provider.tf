# provider.tf contains the provider configuration for the Azure provider. The provider configuration includes the required version of the Terraform Azure provider and the required version of the AzureRM provider.

terraform {
  required_version = "~> 1.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
}