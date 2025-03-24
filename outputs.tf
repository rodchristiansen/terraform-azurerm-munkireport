# outputs.tf contains the output values that are returned after the deployment of the resources.

output "webapp_url" {
  description = "URL of the deployed Azure Web App"
  value       = azurerm_linux_web_app.this.default_hostname
}

output "database_name" {
  description = "Name of the Azure Database instance"
  value       = azurerm_mysql_flexible_server.this.name
}

output "resource_group_name" {
  description = "Name of the Azure Resource Group"
  value       = azurerm_resource_group.this.name
}
