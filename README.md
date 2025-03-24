# Terraform MunkiReport Azure Module

A comprehensive Terraform module to deploy and manage MunkiReport infrastructure on Azure. This module automates provisioning of all necessary Azure resources, streamlining the deployment of a secure, scalable MunkiReport environment.

## Overview

MunkiReport is a popular open-source reporting tool primarily used to manage Apple devices, providing detailed inventory and management data. This module simplifies the deployment of MunkiReport onto Azure by automating the provisioning and configuration of critical infrastructure components including:

- Azure App Service (Linux-based Web App)
- Azure Database for MySQL (Flexible Server)
- Resource groups and associated network configurations

## Features

- Fully automated deployment of MunkiReport infrastructure.
- Configurable resource names and locations for flexibility.
- Secure database provisioning with SSL-enabled MySQL.
- Pre-defined Terraform outputs for easy integration.

## Prerequisites

- Terraform v1.5.0 or later
- Azure subscription with sufficient permissions (Contributor recommended)
- Azure CLI installed and configured for authentication

## Usage

Here's an example demonstrating how to integrate this module into your Terraform workflow:

```hcl
module "munkireport" {
  source  = "registry.terraform.io/<your-username>/munkireport/azurerm"
  version = "1.0.0"

  resource_group_name = "my-munkireport-rg"
  location            = "East US"
  db_admin_user       = "munkireportadmin"
  db_admin_password   = var.db_admin_password
}
```

## Inputs

The following variables can be configured to customize your deployment:

| Name                 | Description                                              | Type   | Required | Default |
|----------------------|----------------------------------------------------------|--------|----------|---------|
| resource_group_name  | Name of the Azure Resource Group to create/use           | string | yes      | -       |
| location             | Azure Region where resources will be deployed            | string | yes      | -       |
| db_admin_user        | Username for the MunkiReport database administrator      | string | yes      | -       |
| db_admin_password    | Password for the MunkiReport database administrator      | string | yes      | -       |
| app_service_plan_sku | SKU for Azure App Service Plan (e.g., B1, S1, P1v2)      | string | no       | B1      |

## Outputs

These outputs are provided by the module to simplify integration and post-deployment management:

| Name                 | Description                                                   |
|----------------------|---------------------------------------------------------------|
| webapp_url           | Fully-qualified URL of the deployed MunkiReport Web Application|
| database_name        | Name of the Azure MySQL database provisioned                  |
| resource_group_name  | Name of the Resource Group containing all deployed resources  |

## Deployment Steps

Follow these steps to deploy MunkiReport:

1. Clone your Terraform module repository and navigate to the deployment directory.
2. Run `terraform init` to initialize Terraform and download dependencies.
3. Execute `terraform plan` to review planned actions.
4. Apply the changes using `terraform apply`.

## Important Caveat

### Database Certificate Handling

This module provisions an Azure Database for MySQL using Azure-managed SSL certificates. These certificates are managed by Azure and are not directly exportable or configurable via Terraform. Therefore, any application or service consuming MunkiReport must explicitly configure their trust to Azure's CA certificates. Refer to Azure’s [official documentation](https://learn.microsoft.com/en-us/azure/mysql/flexible-server/how-to-connect-tls-ssl) to understand how to properly configure secure database connectivity.

## Security Best Practices

- Always secure database credentials using secure Terraform practices, such as Terraform Cloud/Enterprise secrets or environment variables.
- Enable Terraform backend configurations (e.g., Azure Storage, Terraform Cloud) to securely store and version your infrastructure state.

## Troubleshooting

If deployment issues occur:

- Ensure the Azure subscription permissions are correctly configured.
- Check Azure Resource Group and service limits.
- Use `terraform plan` and `terraform apply` with detailed logging enabled (`TF_LOG=DEBUG`) to diagnose problems.

## License

This project is licensed under the MIT License - see the LICENSE file for full details.

