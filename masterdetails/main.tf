terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_client_config" "client" {}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "azurerm_resource_group" "masterdetails" {
  name     = "${local.app_name}-group-${random_string.suffix.result}"
  location = local.location
}

resource "azurerm_virtual_network" "masterdetails" {
  location            = local.location
  name                = "${local.app_name}-network-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.masterdetails.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "network_app_subnet" {
  name                 = "${local.app_name}-app-subnet"
  resource_group_name  = azurerm_resource_group.masterdetails.name
  virtual_network_name = azurerm_virtual_network.masterdetails.name
  address_prefixes     = ["10.0.1.0/24"]

  service_endpoints = [
    "Microsoft.KeyVault"
  ]

  delegation {
    name = "${local.app_name}-app-delegation"

    service_delegation {
      name = "Microsoft.Web/serverFarms"
    }
  }
}

resource "azurerm_subnet" "network_db_subnet" {
  name                 = "${local.app_name}-db-subnet"
  resource_group_name  = azurerm_resource_group.masterdetails.name
  virtual_network_name = azurerm_virtual_network.masterdetails.name
  address_prefixes     = ["10.0.2.0/24"]

  service_endpoints = [
    "Microsoft.Storage"
  ]

  delegation {
    name = "${local.app_name}-db-delegation"

    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
    }
  }
}

# resource "azurerm_subnet" "network_cache_subnet" {
#   name                 = "${local.app_name}-cache-subnet"
#   resource_group_name  = azurerm_resource_group.masterdetails.name
#   virtual_network_name = azurerm_virtual_network.masterdetails.name
#   address_prefixes     = ["10.0.3.0/24"]
#
#   service_endpoints = [
#     "Microsoft.Storage"
#   ]
# }

ephemeral "random_password" "db_admin_password" {
  length      = 16
  lower       = true
  min_lower   = 1
  upper       = true
  min_upper   = 1
  numeric     = true
  min_numeric = 1
  special     = false
}

resource "azurerm_key_vault" "vault" {
  location                      = local.location
  name                          = "${local.app_name_short}-vault-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.masterdetails.name
  sku_name                      = "standard"
  tenant_id                     = data.azurerm_client_config.client.tenant_id
  public_network_access_enabled = true

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
    ip_rules = [
      "94.158.95.152/32"
    ]
    virtual_network_subnet_ids = [
      azurerm_subnet.network_app_subnet.id
    ]
  }

  access_policy {
    tenant_id = data.azurerm_client_config.client.tenant_id
    object_id = data.azurerm_client_config.client.object_id

    secret_permissions = [
      "Get",
      "List",
      "Set",
      "Delete",
      "Purge"
    ]
  }
}

resource "azurerm_key_vault_secret" "db_password_secret" {
  key_vault_id     = azurerm_key_vault.vault.id
  name             = "${local.app_name}-db-admin-password"
  value_wo         = ephemeral.random_password.db_admin_password.result
  value_wo_version = local.db_password_version
}

resource "azurerm_private_dns_zone" "db_dns_zone" {
  name                = "masterdetails.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.masterdetails.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "db_network_link" {
  name                  = "${local.app_name}-db-dnslink"
  private_dns_zone_name = azurerm_private_dns_zone.db_dns_zone.name
  resource_group_name   = azurerm_resource_group.masterdetails.name
  virtual_network_id    = azurerm_virtual_network.masterdetails.id
}

resource "azurerm_postgresql_flexible_server" "masterdetails_db_server" {
  depends_on = [azurerm_private_dns_zone_virtual_network_link.db_network_link]

  name                              = "${local.app_name}-db-server-${random_string.suffix.result}"
  resource_group_name               = azurerm_resource_group.masterdetails.name
  location                          = local.location
  version                           = "17"
  administrator_login               = "masterdetails"
  administrator_password_wo         = ephemeral.random_password.db_admin_password.result
  administrator_password_wo_version = local.db_password_version
  sku_name                          = "B_Standard_B1ms"
  storage_mb                        = 32768
  backup_retention_days             = 7
  public_network_access_enabled     = false
  create_mode                       = "Default"
  delegated_subnet_id               = azurerm_subnet.network_db_subnet.id
  private_dns_zone_id               = azurerm_private_dns_zone.db_dns_zone.id
  zone                              = "1"

  authentication {
    password_auth_enabled = true
  }
}

resource "azurerm_postgresql_flexible_server_database" "masterdetails_database" {
  name      = "masterdetails"
  server_id = azurerm_postgresql_flexible_server.masterdetails_db_server.id
}

resource "azurerm_redis_cache" "redis" {
  capacity                      = 2
  family                        = "C"
  location                      = local.location
  name                          = "${local.app_name}-redis-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.masterdetails.name
  sku_name                      = "Standard"
  non_ssl_port_enabled          = false
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
}

resource "azurerm_service_plan" "masterdetails" {
  location            = local.location
  name                = "${local.app_name}-plan-${random_string.suffix.result}"
  os_type             = "Linux"
  resource_group_name = azurerm_resource_group.masterdetails.name
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "masterdetails" {
  name                          = "${local.app_name}-app-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.masterdetails.name
  location                      = local.location
  service_plan_id               = azurerm_service_plan.masterdetails.id
  https_only                    = true
  public_network_access_enabled = true
  virtual_network_subnet_id     = azurerm_subnet.network_app_subnet.id

  app_settings = {
    PGSQL_HOSTNAME  = azurerm_postgresql_flexible_server.masterdetails_db_server.fqdn
    PGSQL_DATABASE  = azurerm_postgresql_flexible_server_database.masterdetails_database.name
    PGSQL_USERNAME  = azurerm_postgresql_flexible_server.masterdetails_db_server.administrator_login
    AZ_PGSQL_SECRET = azurerm_key_vault_secret.db_password_secret.name
    AZ_VAULT_URI    = azurerm_key_vault.vault.vault_uri
    REDIS_HOSTNAME  = azurerm_redis_cache.redis.hostname
    REDIS_PORT      = azurerm_redis_cache.redis.port
    REDIS_USE_SSL   = true
  }

  site_config {
    application_stack {
      docker_image_name        = "meugen/masterdetails-service:azure-deployment"
      docker_registry_url      = "https://ghcr.io"
      docker_registry_username = var.github_username
      docker_registry_password = var.github_password
    }
  }

  logs {
    application_logs {
      file_system_level = "Verbose"
    }
  }
}

output "url" {
  value = azurerm_linux_web_app.masterdetails.default_hostname
}
