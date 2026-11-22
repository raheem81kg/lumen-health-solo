environment               = "prod"
location                  = "eastus"
vnet_address_space        = ["10.20.0.0/16"]
subnet_address_prefixes   = ["10.20.1.0/24"]

# Set these via environment variables or a local (gitignored) override file:
#   TF_VAR_subscription_id   — your Azure subscription
#   TF_VAR_ssh_public_key    — contents of your public key (e.g. ~/.ssh/id_ed25519.pub)
#   TF_VAR_allowed_ssh_cidr  — optionally narrow to "your.ip/32"
dns_label = "lumen-prod2"
