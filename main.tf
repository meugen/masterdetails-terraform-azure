terraform {
  required_version = "~> 1.14"

  backend "azurerm" {
    resource_group_name  = "common"
    storage_account_name = "meugeninua"
    container_name       = "tfstate"
    key                  = "terraform.tfstate"
  }
}

module "masterdetails" {
  source = "./masterdetails"

  github_username = var.github_username
  github_password = var.github_password
}

output "url" {
  value = module.masterdetails.url
}
