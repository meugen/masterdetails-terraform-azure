terraform {
  required_version = "~> 1.14" # Ensure that the Terraform version is 1.0.0 or higher

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm" # Specify the source of the AWS provider
      version = "~> 4.0"        # Use a version of the AWS provider that is compatible with version
    }
  }
}

terraform {
  backend "azurerm" {
    storage_account_name = "meugeninua"
    container_name = "tfstate"
    key = "terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "example" {
  name     = "example-resources"
  location = "West Europe"
}
