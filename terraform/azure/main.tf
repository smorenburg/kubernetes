terraform {
  required_providers {
    azurerm = {
      version = ">= 3.43"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.4"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.3"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

data "azurerm_client_config" "current" {}

# Get the public IP address
data "http" "public_ip" {
  url = "https://ifconfig.co/ip"
}

locals {
  # Set the application name
  app = "k8s"

  # Lookup and set the location abbreviation, defaults to na (not available).
  location_abbreviation = try(var.location_abbreviation[var.location], "na")

  # Construct the name suffix.
  suffix = "${local.app}-${var.environment}-${local.location_abbreviation}"

  # Clean and set the public IP address
  public_ip = chomp(data.http.public_ip.response_body)
}

# Generate a random suffix for the logs storage account.
resource "random_id" "storage_account" {
  byte_length = 3
}

# Generate a random suffix for the key vault.
resource "random_id" "key_vault" {
  byte_length = 3
}

# Generate an SSH key pair.
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Store the private key locally.
resource "local_sensitive_file" "pem_file" {
  filename             = pathexpand("~/.ssh/id_rsa")
  file_permission      = "600"
  directory_permission = "700"
  content              = tls_private_key.ssh.private_key_pem
}

# Create the resource group.
resource "azurerm_resource_group" "default" {
  name     = "rg-${local.suffix}"
  location = var.location
}

# Create the public key resource.
resource "azurerm_ssh_public_key" "default" {
  name                = "ssh-default"
  location            = var.location
  resource_group_name = azurerm_resource_group.default.name
  public_key          = tls_private_key.ssh.public_key_openssh
}

# Create the Log Analytics workspace.
resource "azurerm_log_analytics_workspace" "default" {
  name                = "log-${local.suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.default.name
  retention_in_days   = 30
}

# Create the storage account for the logs.
resource "azurerm_storage_account" "logs" {
  name                     = "st${local.app}${var.environment}${random_id.storage_account.hex}"
  location                 = var.location
  resource_group_name      = azurerm_resource_group.default.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Create the managed identity.
resource "azurerm_user_assigned_identity" "default" {
  name                = "id-${local.suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.default.name
}

# Create the managed identity for the disk encryption set.
resource "azurerm_user_assigned_identity" "disk_encryption_set" {
  name                = "id-des-${local.suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.default.name
}

# Create the disk encryption set.
resource "azurerm_disk_encryption_set" "default" {
  name                      = "des-${local.suffix}"
  location                  = var.location
  resource_group_name       = azurerm_resource_group.default.name
  key_vault_key_id          = azurerm_key_vault_key.disk_encryption_set.id
  auto_key_rotation_enabled = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.disk_encryption_set.id]
  }

  depends_on = [azurerm_key_vault_access_policy.disk_encryption_set]
}
