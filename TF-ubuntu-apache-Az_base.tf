terraform {
  required_version = ">=0.12"

  required_providers {
    template = {
      source  = "hashicorp/template"
      version = ">= 2.2.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = ">=1.5"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">=3.0"
    }
  }
}

provider "azurerm" {
  features {}
  skip_provider_registration = true
  subscription_id = ""
  client_id       = ""
  client_secret   = ""
  tenant_id       = ""
  
}

resource "random_pet" "ssh_key_name" {
  prefix    = "ssh"
  separator = ""
}

resource "azapi_resource_action" "ssh_public_key_gen" {
  type        = "Microsoft.Compute/sshPublicKeys@2022-11-01"
  resource_id = azapi_resource.ssh_public_key.id
  action      = "generateKeyPair"
  method      = "POST"

  response_export_values = ["publicKey", "privateKey"]
}

resource "azapi_resource" "ssh_public_key" {
  type      = "Microsoft.Compute/sshPublicKeys@2022-11-01"
  name      = random_pet.ssh_key_name.id
  location  = azurerm_resource_group.my_resource_group.location
  parent_id = azurerm_resource_group.my_resource_group.id
}

output "key_data" {
  value = azapi_resource_action.ssh_public_key_gen.output["publicKey"]
}

resource "local_sensitive_file" "private_key" {
  content  = azapi_resource_action.ssh_public_key_gen.output["privateKey"]
  filename = "${path.module}/my_terraform_key"
}

# 1. Create an Azure Resource Group in the East US region.
resource "azurerm_resource_group" "my_resource_group" {
  name     = "myResourceGroup"
  location = "East US"
}

resource "azurerm_virtual_network" "my_terraform_network" {
  name                = "myVnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.my_resource_group.location
  resource_group_name = azurerm_resource_group.my_resource_group.name
}

# Create subnet
resource "azurerm_subnet" "my_terraform_subnet" {
  name                 = "mySubnet"
  resource_group_name  = azurerm_resource_group.my_resource_group.name
  virtual_network_name = azurerm_virtual_network.my_terraform_network.name
  address_prefixes     = ["10.0.1.0/24"]
}

# 3. Allocate a Public IP address for the Virtual Machine.
resource "azurerm_public_ip" "my_public_ip" {
  name                = "myPublicIP"
  resource_group_name = azurerm_resource_group.my_resource_group.name
  allocation_method   = "Static"
  location =  azurerm_resource_group.my_resource_group.location
}

# 4. Configure a Network Security Group to allow inbound traffic on port 80 (HTTP).
resource "azurerm_network_security_group" "my_nsg" {
  name                = "myNetworkSecurityGroup"
  location            = azurerm_resource_group.my_resource_group.location
  resource_group_name = azurerm_resource_group.my_resource_group.name

  security_rule {
    name                       = "AllowHTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# 5. Create a Network Interface with necessary configurations.
resource "azurerm_network_interface" "my_nic" {
  name                      = "myNIC"
  location                  = azurerm_resource_group.my_resource_group.location
  resource_group_name       = azurerm_resource_group.my_resource_group.name

  ip_configuration {
    name                          = "myNICConfig"
    subnet_id                     = azurerm_subnet.my_terraform_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.my_public_ip.id
  }
}

# Generate random text for a unique storage account name
resource "random_id" "random_id" {
  keepers = {
    # Generate a new ID only when a new resource group is defined
    resource_group = azurerm_resource_group.my_resource_group.name
  }

  byte_length = 8
}

# Create storage account for boot diagnostics
resource "azurerm_storage_account" "my_storage_account" {
  name                     = "diag${random_id.random_id.hex}"
  location                 = azurerm_resource_group.my_resource_group.location
  resource_group_name      = azurerm_resource_group.my_resource_group.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

data "template_file" "cloud_init"{
  template = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y apache2
              systemctl enable apache2
              systemctl start apache2
              EOF
}


#6 Create virtual machine
resource "azurerm_linux_virtual_machine" "my_terraform_vm" {
  name                  = "myVM"
  location              = azurerm_resource_group.my_resource_group.location
  resource_group_name   = azurerm_resource_group.my_resource_group.name
  network_interface_ids = [azurerm_network_interface.my_nic.id]
  size                  = "Standard_DS1_v2"

  os_disk {
    name                 = "myOsDisk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  computer_name  = "hostname"
  admin_username = "azureadmin"
  admin_password = "admin-Pass123"

  disable_password_authentication = false

 # admin_ssh_key {
  #  username   = "azureadmin"
   # public_key = azapi_resource_action.ssh_public_key_gen.output["publicKey"]
  #}
  custom_data = base64encode(data.template_file.cloud_init.rendered)

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.my_storage_account.primary_blob_endpoint
  }
}

# 7. Custom script to install Server
resource "azurerm_virtual_machine_extension" "custom_script" {
  name                 = "customScript"
  virtual_machine_id   = azurerm_linux_virtual_machine.my_terraform_vm.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"

  settings = <<SETTINGS
{
  "commandToExecute": "apt-get update && apt-cache search apache2 && apt-get -y install apache2"
}
SETTINGS
}

# 8. Display the public IP address of the VM upon completion.
output "public_ip_address" {
  value = azurerm_public_ip.my_public_ip.ip_address
}