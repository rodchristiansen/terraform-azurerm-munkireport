# variables.tf contains the input variables for the Terraform configuration. These variables are used to parameterize the configuration and allow for reuse of the configuration across different environments.

variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "azure_tenant_id" {
  description = "Azure tenant ID"
  type        = string
}

variable "db_admin_password" {
  description = "Password for the MySQL flexible server administrator"
  type        = string
  sensitive   = true
}

variable "munkireport_username" {
  description = "Username for MunkiReport integration"
  type        = string
}

variable "munkireport_password" {
  description = "Password for MunkiReport integration"
  type        = string
  sensitive   = true
}

variable "devops_resources_owners_entra_group" {
  description = "Azure AD group object ID for DevOps resources owners"
  type        = string
}

variable "google_maps_api_key" {
  type        = string
  description = "Google Maps API key for MunkiReport"
  sensitive   = true
}

variable "base_url" {
  description = "The base URL for the application"
  type        = string
}