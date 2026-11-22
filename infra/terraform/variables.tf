variable "subscription_id" {
  description = "Azure subscription to deploy into. Set via TF_VAR_subscription_id or a tfvars file."
  type        = string
}

variable "project" {
  description = "Name prefix applied to every resource."
  type        = string
  default     = "lumen"
}

variable "environment" {
  description = "Deployment environment name. Used in resource names and tags."
  type        = string

  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be \"staging\" or \"prod\"."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus"
}

variable "vm_size" {
  description = "VM SKU. D2as_v4 (2 vCPU / 8 GB) comfortably runs web + api + Prometheus + Grafana on one box."
  type        = string
  default     = "Standard_D2as_v4"
}

variable "admin_username" {
  description = "Admin user created on the VM."
  type        = string
  default     = "lumenadmin"
}

variable "ssh_public_key" {
  description = "Public key for VM access. Supply via TF_VAR_ssh_public_key (e.g. contents of ~/.ssh/id_ed25519.pub). Never commit private keys."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^ssh-(rsa|ed25519) ", var.ssh_public_key))
    error_message = "ssh_public_key is empty or invalid. Export TF_VAR_ssh_public_key=\"$(cat ~/.ssh/lumen-deploy.pub)\" before applying."
  }
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH to the VM. Narrow to your IP for better security."
  type        = string
  default     = "0.0.0.0/0"
}

variable "vnet_address_space" {
  description = "Address space for the environment's virtual network."
  type        = list(string)
}

variable "subnet_address_prefixes" {
  description = "Address prefixes for the app subnet."
  type        = list(string)
}

variable "app_ports" {
  description = "Application ports opened inbound on the NSG (web, api, grafana, prometheus)."
  type        = list(number)
  default     = [3000, 3001, 3002, 9090]
}

variable "deploy_app_port" {
  description = "Port the public web app is served on."
  type        = number
  default     = 3001
}

variable "dns_label" {
  description = "Domain name label for the public IP (<label>.<region>.cloudapp.azure.com). Defaults to the resource prefix; override when the label is taken/reserved elsewhere."
  type        = string
  default     = ""
}
