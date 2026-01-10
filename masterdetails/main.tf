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
  address_prefixes     = ["10.0.8.0/21"]

  service_endpoints = [
    "Microsoft.KeyVault",
    "Microsoft.Storage"
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
  address_prefixes     = ["10.0.16.0/21"]

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

resource "random_password" "db_admin_password" {
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
  key_vault_id = azurerm_key_vault.vault.id
  name         = "${local.app_name}-db-admin-password"
  value        = random_password.db_admin_password.result
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

  name                          = "${local.app_name}-db-server-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.masterdetails.name
  location                      = local.location
  version                       = "17"
  administrator_login           = "masterdetails"
  administrator_password        = random_password.db_admin_password.result
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  backup_retention_days         = 7
  public_network_access_enabled = false
  create_mode                   = "Default"
  delegated_subnet_id           = azurerm_subnet.network_db_subnet.id
  private_dns_zone_id           = azurerm_private_dns_zone.db_dns_zone.id
  zone                          = "1"

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

data "azurerm_key_vault" "github_tokens_vault" {
  name                = var.github_vault_name
  resource_group_name = var.github_vault_group
}

data "azurerm_key_vault_secret" "github_password_secret" {
  name         = var.github_password_secret
  key_vault_id = data.azurerm_key_vault.github_tokens_vault.id
}

resource "azurerm_log_analytics_workspace" "masterdetails" {
  location            = local.location
  name                = "${local.app_name}-law-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.masterdetails.name
}

resource "azurerm_container_app_environment" "masterdetails" {
  location                   = local.location
  name                       = "${local.app_name}-app-env-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.masterdetails.name
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.masterdetails.id
  infrastructure_subnet_id   = azurerm_subnet.network_app_subnet.id
}

resource "azurerm_container_app" "masterdetails" {
  container_app_environment_id = azurerm_container_app_environment.masterdetails.id
  name                         = "${local.app_name}-app-${random_string.suffix.result}"
  resource_group_name          = azurerm_resource_group.masterdetails.name
  revision_mode                = "Single"

  ingress {
    target_port                = 8080
    allow_insecure_connections = false
    external_enabled           = true

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  registry {
    server               = "ghcr.io"
    username             = var.github_username
    password_secret_name = "github-password-secret"
  }

  secret {
    name  = "github-password-secret"
    value = data.azurerm_key_vault_secret.github_password_secret.value
  }

  secret {
    name  = "db-password-secret"
    value = random_password.db_admin_password.result
  }

  template {
    container {
      name   = "masterdetails-service"
      image  = "ghcr.io/meugen/masterdetails-service:main"
      cpu    = 0.5
      memory = "1.0Gi"

      env {
        name  = "PGSQL_HOSTNAME"
        value = azurerm_postgresql_flexible_server.masterdetails_db_server.fqdn
      }

      env {
        name  = "PGSQL_DATABASE"
        value = azurerm_postgresql_flexible_server_database.masterdetails_database.name
      }

      env {
        name  = "PGSQL_USERNAME"
        value = azurerm_postgresql_flexible_server.masterdetails_db_server.administrator_login
      }

      env {
        name        = "PGSQL_PASSWORD"
        secret_name = "db-password-secret"
      }

      env {
        name  = "AZ_VAULT_URI"
        value = azurerm_key_vault.vault.vault_uri
      }

      env {
        name  = "REDIS_HOSTNAME"
        value = azurerm_redis_cache.redis.hostname
      }

      env {
        name  = "REDIS_PORT"
        value = azurerm_redis_cache.redis.port
      }

      env {
        name  = "REDIS_USE_SSL"
        value = "true"
      }

      readiness_probe {
        path      = "/actuator/health"
        port      = 8080
        transport = "HTTP"

        initial_delay    = 10
        interval_seconds = 5
      }
    }
  }
}

# resource "azurerm_container_group" "masterdetails" {
#   name                = "${local.app_name}-app-${random_string.suffix.result}"
#   resource_group_name = azurerm_resource_group.masterdetails.name
#   location            = local.location
#   os_type             = "Linux"
#   restart_policy      = "Always"
#   ip_address_type     = "Public"
#
#   exposed_port {
#     port     = 8080
#     protocol = "TCP"
#   }
#
#   image_registry_credential {
#     server   = "ghcr.io"
#     username = var.github_username
#     password = data.azurerm_key_vault_secret.github_password_secret.value
#   }
#
#   container {
#     cpu    = 2
#     image  = "ghcr.io/meugen/masterdetails-service:azure-deployment"
#     memory = 1
#     name   = "masterdetails-service"
#
#     environment_variables = {
#       "PGSQL_HOSTNAME"  = azurerm_postgresql_flexible_server.masterdetails_db_server.fqdn
#       "PGSQL_DATABASE"  = azurerm_postgresql_flexible_server_database.masterdetails_database.name
#       "PGSQL_USERNAME"  = azurerm_postgresql_flexible_server.masterdetails_db_server.administrator_login
#       "AZ_PGSQL_SECRET" = azurerm_key_vault_secret.db_password_secret.name
#       "AZ_VAULT_URI"    = azurerm_key_vault.vault.vault_uri
#       "REDIS_HOSTNAME"  = azurerm_redis_cache.redis.hostname
#       "REDIS_PORT"      = azurerm_redis_cache.redis.port
#       "REDIS_USE_SSL"   = "true"
#     }
#
#     ports {
#       port     = 8080
#       protocol = "TCP"
#     }
#
#     readiness_probe {
#       http_get {
#         path = "/actuator/health"
#         port = 8080
#       }
#       initial_delay_seconds = 10
#       period_seconds        = 5
#     }
#
#   }
#
#   diagnostics {
#     log_analytics {
#       workspace_id  = azurerm_log_analytics_workspace.masterdetails.workspace_id
#       workspace_key = azurerm_log_analytics_workspace.masterdetails.primary_shared_key
#       log_type = "ContainerInsights"
#     }
#   }
#
# }

output "url" {
  value = azurerm_container_app.masterdetails.latest_revision_fqdn
}
