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

  github_username        = var.github_username
  github_vault_group     = var.github_vault_group
  github_vault_name      = var.github_vault_name
  github_password_secret = var.github_password_secret
}

output "url" {
  value = module.masterdetails.url
}
