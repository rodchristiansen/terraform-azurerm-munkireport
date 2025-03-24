# main.tf contains the main Terraform configuration for deploying the resources to Azure.

###########################################################
# Data Source: Azure Client Config (for tenant info)
###########################################################
data "azurerm_client_config" "current" {}

###########################################################
# Resource Group
###########################################################
resource "azurerm_resource_group" "reporting_rg" {
  name     = "Reporting"
  location = "Canada Central"
  tags = {
    GitOps = "Terraformed"
  }
}

###########################################################
# Key Vault for Secrets
###########################################################
resource "azurerm_key_vault" "reporting_creds" {
  name                        = "reporting-creds"
  location                    = azurerm_resource_group.reporting_rg.location
  resource_group_name         = azurerm_resource_group.reporting_rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  soft_delete_retention_days  = 7
  purge_protection_enabled    = true
  enable_rbac_authorization   = true

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}

resource "azurerm_role_assignment" "reporting_key_vault_admin" {
  scope                = azurerm_key_vault.reporting_creds.id
  role_definition_name = "Key Vault Administrator"
  principal_type       = "Group"
  principal_id         = var.devops_resources_owners_entra_group
}

locals {
  reporting_secrets_map = {
    AzureTenantId       = var.azure_tenant_id
    DbAdminPassword     = var.db_admin_password
    MunkiReportUsername = var.munkireport_username
    MunkiReportPassword = var.munkireport_password
  }
}

resource "azurerm_key_vault_secret" "reporting_secrets" {
  for_each     = local.reporting_secrets_map
  name         = each.key
  value        = each.value
  key_vault_id = azurerm_key_vault.reporting_creds.id
}

###########################################################
# Virtual Network & Subnets
###########################################################
resource "azurerm_virtual_network" "reporting_vnet" {
  name                = "reporting-vnet"
  address_space       = ["10.1.0.0/16"]
  location            = azurerm_resource_group.reporting_rg.location
  resource_group_name = azurerm_resource_group.reporting_rg.name
}

# App Service subnet
resource "azurerm_subnet" "reporting_appservice_subnet" {
  name                 = "reporting-appservice-subnet"
  resource_group_name  = azurerm_resource_group.reporting_rg.name
  virtual_network_name = azurerm_virtual_network.reporting_vnet.name
  address_prefixes     = ["10.1.2.0/24"]

  delegation {
    name = "webappDelegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# MySQL subnet (for database delegation)
resource "azurerm_subnet" "reporting_mysql_subnet" {
  name                 = "reporting-mysql-subnet"
  resource_group_name  = azurerm_resource_group.reporting_rg.name
  virtual_network_name = azurerm_virtual_network.reporting_vnet.name
  address_prefixes     = ["10.1.3.0/24"]

  delegation {
    name = "mysqlDelegation"
    service_delegation {
      name    = "Microsoft.DBforMySQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Private Endpoints subnet – used for private connections
resource "azurerm_subnet" "reporting_private_endpoints_subnet" {
  name                          = "reporting-private-endpoints-subnet"
  resource_group_name           = azurerm_resource_group.reporting_rg.name
  virtual_network_name          = azurerm_virtual_network.reporting_vnet.name
  address_prefixes              = ["10.1.4.0/24"]
  private_endpoint_network_policies = "Disabled"
}

###########################################################
# Public IP & NAT Gateway for Outbound App Service Traffic
###########################################################
resource "azurerm_public_ip" "reporting_webapp_nat_ip" {
  name                = "reporting-webapp-nat-ip"
  location            = azurerm_resource_group.reporting_rg.location
  resource_group_name = azurerm_resource_group.reporting_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "reporting_nat_gateway" {
  name                    = "reporting-webapp-nat-gateway"
  location                = azurerm_resource_group.reporting_rg.location
  resource_group_name     = azurerm_resource_group.reporting_rg.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
}

resource "azurerm_nat_gateway_public_ip_association" "reporting_nat_ip_assoc" {
  nat_gateway_id       = azurerm_nat_gateway.reporting_nat_gateway.id
  public_ip_address_id = azurerm_public_ip.reporting_webapp_nat_ip.id
}

resource "azurerm_subnet_nat_gateway_association" "reporting_subnet_nat_assoc" {
  subnet_id      = azurerm_subnet.reporting_appservice_subnet.id
  nat_gateway_id = azurerm_nat_gateway.reporting_nat_gateway.id
}

resource "azurerm_subnet_network_security_group_association" "reporting_nsg_assoc" {
  subnet_id                 = azurerm_subnet.reporting_appservice_subnet.id
  network_security_group_id = azurerm_network_security_group.reporting_vnet_nsg.id
}

###########################################################
# MySQL Flexible Server for Managed Reports
###########################################################
resource "azurerm_mysql_flexible_server" "reporting_db" {
  name                   = "reporting-db-flexible-server"
  resource_group_name    = azurerm_resource_group.reporting_rg.name
  location               = azurerm_resource_group.reporting_rg.location
  administrator_login    = "reportingadmin"
  administrator_password = var.db_admin_password
  sku_name               = "B_Standard_B1ms"
  version                = "8.0.21"
  zone                   = "1"

  delegated_subnet_id = azurerm_subnet.reporting_mysql_subnet.id

  storage {
    iops    = 360
    size_gb = 20
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_mysql_flexible_database" "reporting_db_instance" {
  name                = "munkireport"
  resource_group_name = azurerm_mysql_flexible_server.reporting_db.resource_group_name
  server_name         = azurerm_mysql_flexible_server.reporting_db.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
  
  depends_on = [azurerm_mysql_flexible_server.reporting_db]
  lifecycle {
    prevent_destroy = true
  }
}

# Enforce SSL
resource "azurerm_mysql_flexible_server_configuration" "require_secure_transport" {
  name                = "require_secure_transport"
  resource_group_name = azurerm_resource_group.reporting_rg.name
  server_name         = azurerm_mysql_flexible_server.reporting_db.name
  value               = "ON"
}

resource "azurerm_mysql_flexible_server_configuration" "tls_version" {
  name                = "tls_version"
  resource_group_name = azurerm_resource_group.reporting_rg.name
  server_name         = azurerm_mysql_flexible_server.reporting_db.name
  value               = "TLSv1.2"
}

# Set slow query threshold to 2s
resource "azurerm_mysql_flexible_server_configuration" "long_query_time" {
  name                = "long_query_time"
  resource_group_name = azurerm_resource_group.reporting_rg.name
  server_name         = azurerm_mysql_flexible_server.reporting_db.name
  value               = "2"
}

###########################################################
# Storage Account for Logs and Cache
###########################################################
resource "azurerm_storage_account" "reporting_storage" {
  name                     = "reportingdevices"
  resource_group_name      = azurerm_resource_group.reporting_rg.name
  location                 = azurerm_resource_group.reporting_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "reporting_cache" {
  name                = "reports-cache"
  storage_account_id  = azurerm_storage_account.reporting_storage.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "reporting_logs" {
  name                = "reports-logs"
  storage_account_id  = azurerm_storage_account.reporting_storage.id
  container_access_type = "private"
}

###########################################################
# MunkiReport Certificate Storage
###########################################################
# variable "munkireport_cert_pem" {
#   type        = string
#   description = "Raw PEM text for DigiCert root certificate"
#   default = <<-EOF
# -----BEGIN CERTIFICATE-----
# MIIDrzCCApegAwIBAgIQCDvgVpBCRrGhdWrJWZHHSjANBgkqhkiG9w0BAQUFADBh
# MQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLEwB3
# d3cuZGlnaWNlcnQuY29tMSAwHgYDVQQDExdEaWdpQ2VydCBHbG9iYWwgUm9vdCBD
# QTAeFw0wNjExMTAwMDAwMDBaFw0zMTExMTAwMDAwMDBaMGExCzAJBgNVBAYTAlVT
# MRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5j
# b20xIDAeBgNVBAMTF0RpZ2lDZXJ0IEdsb2JhbCBSb290IENBMIIBIjANBgkqhkiG
# 9w0BAQEFAAOCAQ8AMIIBCgKCAQEA4jvhEXLeqKTTo1eqUKKPC3eQyaKl7hLOllsB
# CSDMAZOnTjC3U/dDxGkAV53ijSLdhwZAAIEJzs4bg7/fzTtxRuLWZscFs3YnFo97
# nh6Vfe63SKMI2tavegw5BmV/Sl0fvBf4q77uKNd0f3p4mVmFaG5cIzJLv07A6Fpt
# 43C/dxC//AH2hdmoRBBYMql1GNXRor5H4idq9Joz+EkIYIvUX7Q6hL+hqkpMfT7P
# T19sdl6gSzeRntwi5m3OFBqOasv+zbMUZBfHWymeMr/y7vrTC0LUq7dBMtoM1O/4
# gdW7jVg/tRvoSSiicNoxBN33shbyTApOB6jtSj1etX+jkMOvJwIDAQABo2MwYTAO
# BgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUA95QNVbR
# TLtm8KPiGxvDl7I90VUwHwYDVR0jBBgwFoAUA95QNVbRTLtm8KPiGxvDl7I90VUw
# DQYJKoZIhvcNAQEFBQADggEBAMucN6pIExIK+t1EnE9SsPTfrgT1eXkIoyQY/Esr
# hMAtudXH/vTBH1jLuG2cenTnmCmrEbXjcKChzUyImZOMkXDiqw8cvpOp/2PV5Adg
# 06O/nVsJ8dWO41P0jmP6P6fbtGbfYmbW0W5BjfIttep3Sp+dWOIrWcBAI+0tKIJF
# PnlUkiaY4IBIqDfv8NZ5YBberOgOzW6sRBc4L0na4UU+Krk2U886UAb3LujEV0ls
# YSEY1QSteDwsOoBrp+uvFRTp2InBuThs4pFsiv9kuXclVzDAGySj4dzp30d8tbQk
# CAUw7C29C79Fv1C5qfPrmAESrciIxpg0X40KPMbp1ZWVbd4=
# -----END CERTIFICATE-----
# EOF
# }

# # Decode & Write the Certificate Locally
# resource "local_file" "munkireport_cert_file" {
#   content  = var.munkireport_cert_pem
#   filename = "${path.module}/DigiCertGlobalRootCA.crt.pem"
# }

# Create Storage Account & File Share for MunkiReport
resource "azurerm_storage_account" "munkireport_storage" {
  name                     = "munkireportstorage"
  resource_group_name      = azurerm_resource_group.reporting_rg.name
  location                 = azurerm_resource_group.reporting_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_share" "munkireport_share" {
  name                 = "munkireportcerts"
  storage_account_id   = azurerm_storage_account.munkireport_storage.id
  quota                = 5
}

# resource "azurerm_storage_share_file" "munkireport_cert" {
#   name             = "DigiCertGlobalRootCA.crt.pem"
#   storage_share_id = azurerm_storage_share.munkireport_share.id
#   source           = local_file.munkireport_cert_file.filename
# }

###########################################################
# App Service Plan & Web App for Managed Reports
###########################################################
resource "azurerm_service_plan" "reporting_asp" {
  name                = "reporting-app-service-plan"
  location            = azurerm_resource_group.reporting_rg.location
  resource_group_name = azurerm_resource_group.reporting_rg.name
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "reporting_app" {
  name                       = "reporting-devices-web-app"
  resource_group_name        = azurerm_resource_group.reporting_rg.name
  location                   = azurerm_resource_group.reporting_rg.location
  service_plan_id            = azurerm_service_plan.reporting_asp.id
  virtual_network_subnet_id  = azurerm_subnet.reporting_appservice_subnet.id

  site_config {
    ftps_state               = "Disabled"
    http2_enabled            = true
    vnet_route_all_enabled   = true
    remote_debugging_enabled = false

    application_stack {
      docker_image_name         = "munkireport/munkireport-php:wip"
      docker_registry_url       = "https://ghcr.io"
    }
  }

  # storage_account {
  #   name            = "munkireport-certs"
  #   account_name    = azurerm_storage_account.munkireport_storage.name
  #   share_name      = azurerm_storage_share.munkireport_share.name
  #   access_key      = azurerm_storage_account.munkireport_storage.primary_access_key
  #   mount_path      = "/var/munkireport/local/certs"
  #   type            = "AzureFiles"
  # }
  
  app_settings = {
    "APPINSIGHTS_INSTRUMENTATIONKEY"             = azurerm_application_insights.reporting_appinsights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING"      = azurerm_application_insights.reporting_appinsights.connection_string
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE"        = "true"
    "WEBSITES_ENABLE_SSH"                        = "true"
    "SITENAME"                                   = "Devices Cloud Monitoring"
    "BASE_URL"                                   = var.base_url
    "TIMEZONE"                                   = "PST"
    "DEBUG"                                      = "FALSE"
    "CUSTOM_JS"                                  = "custom.js"
    "CONNECTION_DRIVER"                          = "mysql"
    "CONNECTION_PORT"                            = "3306"
    "CONNECTION_HOST"                            = azurerm_mysql_flexible_server.reporting_db.fqdn
    "CONNECTION_DATABASE"                        = azurerm_mysql_flexible_database.reporting_db_instance.name
    "CONNECTION_USERNAME"                        = azurerm_mysql_flexible_server.reporting_db.administrator_login
    "CONNECTION_PASSWORD"                        = var.db_admin_password
    "CONNECTION_CHARSET"                         = "utf8mb4"
    "CONNECTION_COLLATION"                       = "utf8mb4_unicode_ci"
    "CONNECTION_STRICT"                          = "TRUE"
    "CONNECTION_ENGINE"                          = "InnoDB"
    "CONNECTION_SSL_ENABLED"                     = "TRUE"
    "CONNECTION_SSL_CA"                          = "/usr/local/share/ca-certificates/DigiCertGlobalRootCA.crt.pem"
    "PDO_MYSQL_ATTR_SSL_CA"                      = "/usr/local/share/ca-certificates/DigiCertGlobalRootCA.crt.pem"
    "PDO_MYSQL_ATTR_SSL_VERIFY_SERVER_CERT"      = "true"
    "AUTH_METHODS"                               = "SAML"
    "AUTH_SAML_SP_NAME_ID_FORMAT"                = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
    "AUTH_SAML_IDP_ENTITY_ID"                    = "https://sts.windows.net/${var.azure_tenant_id}/"
    "AUTH_SAML_IDP_SSO_URL"                      = "https://login.microsoftonline.com/${var.azure_tenant_id}/saml2"
    "AUTH_SAML_IDP_SLO_URL"                      = "https://login.microsoftonline.com/${var.azure_tenant_id}/saml2"
    "AUTH_SAML_USER_ATTR"                        = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name"
    "AUTH_SAML_ALLOWED_USERS"                    = "user1@example.com, user2@example.com"
    "AUTH_SAML_GROUP_ATTR"                       = "http://schemas.microsoft.com/ws/2008/06/identity/claims/groups"
    "AUTH_SAML_IDP_X509CERT"                     = "-----BEGIN CERTIFICATE-----MIIC8DCCAdigAwIBAgIQF00ddZF/55BJoFdJb0nDEjANBgkqhkiG9w0BAQsFADA0MTIwMAYDVQQDEylNaWNyb3NvZnQgQXp1cmUgRmVkZXJhdGVkIFNTTyBDZXJ0aWZpY2F0ZTAeFw0yMzExMDcwMDEzMzFaFw0yNjExMDcwMDEzMzFaMDQxMjAwBgNVBAMTKU1pY3Jvc29mdCBBenVyZSBGZWRlcmF0ZWQgU1NPIENlcnRpZmljYXRlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnEdr8bL+w2GIYNoXNS32gZ5KFv9wAaDAAij2Q/GvF9sZ47uHuedEVHMu8q5NvVc+Hd9jFGUUUit0GftxI4LGIyMpSRuwhxZniNQHr+2gbTadYO+aBF1fPPEuM8inYAYbYGKeCBpyNLc/DumgNYx0EwaY9uN7k/fHywMH14Gk93nAeNfjjXjObSGlYREc+Bqo5cMTQUKr8Yq59UL/ya2lPymh5tZzXMQ3ySCxna8gEAsmeP3STM0T7kQ84oWfj3jRzTAgdntjeYFZ++eA3ZXZXQ9XQaBWzqXxWwevpd3w1X8f7hLRfXEoCwdfFg3uWDucQQ/zarZremBpyywjyN+wgQIDAQABMA0GCSqGSIb3DQEBCwUAA4IBAQAUlQCJGCy7lTXSNcgxkmh3nYQ4drLCnmNg5jOFakZRgssHiPHXRs5SVCYFG4qZbgdGgTAp/zN+r2o1WkLenqiT/g0LPJ+cYaMQ2MgLeE8BDepQNIBixZBzTUzxBfpWq/cnPk2WOI4ftDbIso9CbiX7LnNan7faboH6Om7Ivl5owCB8dTI1VQ7KEzX6RLmnFZ1ymEyRNiH14Z8MAwjaMSFVegtTjDaOAq5ScKN/vo0+/QVN2+e7BSlpxxsRZWMTcpMpqOnDNuc2UHkmqXu/i0FnPo4sjm2aN2jbr6Rr0nVIQxl3/3fSZsSwVi/1ubz0Ho2nOkckryTol4kJNjoFq56k-----END CERTIFICATE-----"
    "AUTH_SAML_ALLOWED_GROUPS"                   = "${var.devops_resources_owners_entra_group}"
    "AUTH_SAML_DEBUG"                            = "FALSE"
    "AUTH_SAML_SECURITY_REQUESTED_AUTHN_CONTEXT" = "FALSE" # if you have a Passkey based auth
    "AUTHORIZATION_GLOBAL"                       = "admin"
    "AUTHORIZATION_DELETE_MACHINE"               = "admin,manager"
    "HIDE_INACTIVE_MODULES"                      = "TRUE"
    "MODULES"                                    = "filevault_status, filevault_escrow, apps_32, applications, appusage, ard, background_items, bluetooth, browser_extensions, certificate, comment, detectx, disk_report, displays_info, extensions, fan_temps, findmymac, fonts, gpu, icloud, launchdaemons, kernel_panics, ms_defender, munki_facts, munkireportinfo, network_shares, sophos, usage_stats, usb, supported_os, installhistory, inventory, location, managedinstalls, machine, macos_security_compliance, mdm_status, munkireport, munkiinfo, ms_office, nudge, printer, firewall, security, network, power, profile, reportdata, softwareupdate, timemachine, users, user_sessions, warranty, wifi"
    "MODULE_SEARCH_PATHS"                        = "/home/ubuntu/munkireport/vendor/tuxudo/"
    "VNC_LINK"                                   = "vnc://admin@%network_ip_v4:5900"
    "SSH_LINK"                                   = "ssh://admin@%s"
    "APPS_TO_TRACK"                              = "Microsoft Teams,Microsoft Teams (work or school),zoom.us,Xcode,Logic Pro X,Pro Tools,Final Cut Pro, Compressor, Motion, DaVinci Resolve, Adobe Photoshop%, Adobe Illustrator%, Adobe InDesign%, Adobe Bridge%, Adobe After Effects%, Adobe Premiere%, Adobe Media Encoder%, Adobe Acrobat%, Adobe Animate%, Adobe Audition%, Adobe Prelude%, WacomTouchDriver, BBEdit, Suspicious Package, Flash Player, Silverlight, Safari, Google Chrome, Firefox, Microsoft Excel, Microsoft PowerPoint, Microsoft Word, Pages, Numbers, Keynote, iMovie, GarageBand, Skype, MirrorOp, MiCollab, VLC, REAPER64, Ableton Live 10 Suite, Ableton Live 11 Suite"
    "BUNDLEID_IGNORELIST"                        = "com.parallels.winapp.*, com.vmware.proxyApp.*"
    "BUNDLEPATH_IGNORELIST"                      = "/System/Library/.*"
    "GOOGLE_MAPS_API_KEY"                        = var.google_maps_api_key
    "ENABLE_BUSINESS_UNITS"                      = "TRUE"
  }

  https_only = true

  logs {
    application_logs {
      file_system_level = "Error"
    }
    http_logs {
      file_system {
        retention_in_mb   = 100
        retention_in_days = 7
      }
    }
  }

  identity {
    type = "SystemAssigned"
  }
}

# Write the IDP certificate to the webroot for SAML
resource "local_file" "idp_crt" {
  content  = local.idp_certificate
  filename = "${path.module}/webroot/munkireport/local/certs/idp.crt"
}

###########################################################
# App Service VNet connection to subnet
###########################################################
resource "azurerm_app_service_virtual_network_swift_connection" "reporting_vnet_connection" {
  app_service_id = azurerm_linux_web_app.reporting_app.id
  subnet_id      = azurerm_subnet.reporting_appservice_subnet.id
}

###########################################################
# Application Insights for Monitoring
###########################################################
resource "azurerm_application_insights" "reporting_appinsights" {
  name                = "reporting-app-insights"
  location            = azurerm_resource_group.reporting_rg.location
  resource_group_name = azurerm_resource_group.reporting_rg.name
  application_type    = "web"
}

###########################################################
# Network Security Group & Association
###########################################################
resource "azurerm_network_security_group" "reporting_vnet_nsg" {
  name                = "reporting-vnet-nsg"
  location            = azurerm_resource_group.reporting_rg.location
  resource_group_name = azurerm_resource_group.reporting_rg.name

  security_rule {
    name                       = "allow-https"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "allow-mysql-from-appservice"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3306"
    source_address_prefix      = "10.1.2.0/24"
    destination_address_prefix = "10.1.3.0/24"
  }
  security_rule {
    name                       = "allow-mysql-privateendpoint"
    priority                   = 115
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3306"
    source_address_prefix      = "10.1.2.0/24"
    destination_address_prefix = "10.1.4.0/24"
  }
}