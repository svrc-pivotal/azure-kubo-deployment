resource "azurerm_public_ip" "bastion" {
  name                         = "${var.prefix}-bastion-ip"
  location                     = "${var.location}"
  depends_on                   = ["azurerm_resource_group.rg"]
  resource_group_name          = "${azurerm_resource_group.rg.name}"
  public_ip_address_allocation = "static"
  sku                          = "Standard"

  tags {
    environment = "${module.variables.environment-tag}"
  }
}

// BOSH bastion host
resource "azurerm_network_interface" "bastion" {
  name                      = "${var.prefix}-bastion-nic"
  depends_on                = ["azurerm_public_ip.bastion", "azurerm_subnet.bosh-subnet", "azurerm_network_security_group.bastion"]
  location                  = "${var.location}"
  resource_group_name       = "${azurerm_resource_group.rg.name}"
  network_security_group_id = "${azurerm_network_security_group.bastion.id}"

  ip_configuration {
    name                          = "${var.prefix}-bastion-ip-config"
    subnet_id                     = "${azurerm_subnet.bosh-subnet.id}"
    private_ip_address_allocation = "static"
    private_ip_address            = "${cidrhost(azurerm_subnet.bosh-subnet.address_prefix,100)}"
    public_ip_address_id          = "${azurerm_public_ip.bastion.id}"
  }
}

resource "azurerm_virtual_machine" "bastion" {
  name                    = "${var.prefix}-bastion"
  depends_on              = ["azurerm_network_interface.bastion"]
  vm_size                 = "Standard_D1_v2"
  location                = "${var.location}"
  resource_group_name     = "${azurerm_resource_group.rg.name}"
  network_interface_ids   = ["${azurerm_network_interface.bastion.id}"]
  storage_image_reference = ["${var.latest_ubuntu}"]

  storage_os_disk {
    name              = "osdisk1"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
    disk_size_gb      = "50"
  }

  os_profile_linux_config {
    disable_password_authentication = true

    ssh_keys = [{
      path     = "/home/${var.ssh_user_username}/.ssh/authorized_keys"
      key_data = "${file(var.ssh_public_key_filename)}"
    }]
  }

  os_profile {
    computer_name  = "bastion"
    admin_username = "${var.ssh_user_username}"

    custom_data = <<EOT
#!/bin/bash
cat > /etc/motd <<EOF




#    #     ##     #####    #    #   #   #    #    ####
#    #    #  #    #    #   ##   #   #   ##   #   #    #
#    #   #    #   #    #   # #  #   #   # #  #   #
# ## #   ######   #####    #  # #   #   #  # #   #  ###
##  ##   #    #   #   #    #   ##   #   #   ##   #    #
#    #   #    #   #    #   #    #   #   #    #    ####

Startup scripts have not finished running, and the tools you need
are not ready yet. Please log out and log back in again in a few moments.
This warning will not appear when the system is ready.
EOF

apt-get update
apt-get install -y build-essential zlibc zlib1g-dev ruby ruby-dev openssl libxslt-dev libxml2-dev libssl-dev libreadline6 libreadline6-dev libyaml-dev libsqlite3-dev sqlite3 jq git unzip
curl -o /tmp/cf.tgz https://s3.amazonaws.com/go-cli/releases/v6.20.0/cf-cli_6.20.0_linux_x86-64.tgz
tar -zxvf /tmp/cf.tgz && mv cf /usr/bin/cf && chmod +x /usr/bin/cf

cat > /etc/profile.d/bosh.sh <<'EOF'
#!/bin/bash
# Vars from Terraform
export tenant_id=${var.tenant_id}
export client_id=${var.client_id}
export client_secret=${var.client_secret}
export resource_group_name=${azurerm_resource_group.rg.name}
export vnet_name=${module.variables.vnet-name}
export cfcr_subnet_name=${azurerm_subnet.cfcr-subnet.name}
export cfcr_master_sg_name=${azurerm_network_security_group.cfcr-master.name}
export cfcr_subnet_address_range=${azurerm_subnet.cfcr-subnet.address_prefix}
export cfcr_internal_ip=${cidrhost(azurerm_subnet.cfcr-subnet.address_prefix, 5)}
export cfcr_internal_gw=${cidrhost(azurerm_subnet.cfcr-subnet.address_prefix, 1)}
export location=${var.location}
export bosh_director_name=${var.bosh_director_name}
export subscription_id=${var.subscription_id}
export kubernetes_master_host=${azurerm_public_ip.cfcr-balancer-ip.ip_address}
export kubernetes_master_port=${var.kubernetes_master_port}
export master_target_pool=${azurerm_lb.cfcr-balancer.name}
export allow_privileged_containers=${var.allow_privileged_containers}
export disable_deny_escalating_exec=${var.disable_deny_escalating_exec}
EOF

cat > /usr/bin/update_azure_env <<'EOF'
#!/bin/bash

if [[ ! -f "$1" ]] || [[ ! "$1" =~ director.yml$ ]]; then
  echo 'Please specify the path to director.yml'
  exit 1
fi

# Azure specific updates
sed -i -e 's/^\(resource_group_name:\).*\(#.*\)/\1 ${azurerm_resource_group.rg.name} \2/' "$1"
sed -i -e 's/^\(vnet_resource_group_name:\).*\(#.*\)/\1 ${azurerm_resource_group.rg.name} \2/' "$1"
sed -i -e 's/^\(vnet_name:\).*\(#.*\)/\1 ${azurerm_virtual_network.vnet.name} \2/' "$1"
sed -i -e 's/^\(subnet_name:\).*\(#.*\)/\1 ${azurerm_subnet.cfcr-subnet.name} \2/' "$1"
sed -i -e 's/^\(location:\).*\(#.*\)/\1 ${var.location} \2/' "$1"
sed -i -e 's/^\(default_security_group:\).*\(#.*\)/\1 ${azurerm_network_security_group.cfcr-master.name} \2/' "$1"
sed -i -e 's/^\(master_vm_type:\).*\(#.*\)/\1 'master' \2/' "$1"
sed -i -e 's/^\(worker_vm_type:\).*\(#.*\)/\1 'worker' \2/' "$1"
sed -i -e 's/^\(allow_privileged_containers:\).*\(#.*\)/\1 ${var.allow_privileged_containers} \2/' "$1"
sed -i -e 's/^\(disable_deny_escalating_exec:\).*\(#.*\)/\1 ${var.disable_deny_escalating_exec} \2/' "$1"

# Generic updates
sed -i -e 's/^\(internal_ip:\).*\(#.*\)/\1 ${cidrhost(azurerm_subnet.cfcr-subnet.address_prefix, 5)} \2/' "$1"
sed -i -e 's=^\(internal_cidr:\).*\(#.*\)=\1 ${azurerm_subnet.cfcr-subnet.address_prefix} \2=' "$1"
sed -i -e 's/^\(internal_gw:\).*\(#.*\)/\1 ${cidrhost(azurerm_subnet.cfcr-subnet.address_prefix, 1)} \2/' "$1"
sed -i -e 's/^\(director_name:\).*\(#.*\)/\1 ${var.prefix}bosh \2/' "$1"

EOF
chmod a+x /usr/bin/update_azure_env

cat > /usr/bin/update_azure_secrets <<'EOF'
#!/bin/bash

if [[ ! -f "$1" ]] || [[ ! "$1" =~ director-secrets.yml$ ]]; then
  echo 'Please specify the path to director-secrets.yml'
  exit 1
fi

# Azure secrets updates
sed -i -e 's/^\(subscription_id:\).*\(#.*\)/\1 ${var.subscription_id} \2/' "$1"
sed -i -e 's=^\(tenant_id:\).*\(#.*\)=\1 ${var.tenant_id} \2=' "$1"
sed -i -e 's/^\(client_id:\).*\(#.*\)/\1 ${var.client_id} \2/' "$1"
sed -i -e 's/^\(client_secret:\).*\(#.*\)/\1 ${var.client_secret} \2/' "$1"

EOF
chmod a+x /usr/bin/update_azure_secrets


cat > /usr/bin/set_iaas_routing <<'EOF'
#!/bin/bash

if [[ ! -f "$1" ]] || [[ ! "$1" =~ director.yml$ ]]; then
  echo 'Please specify the path to director.yml'
  exit 1
fi

sed -i -e 's/^#* *\(routing_mode:.*\)$/# \1/' "$1"
sed -i -e 's/^#* *\(routing_mode:\) *\(iaas\).*$/\1 \2/' "$1"

sed -i -e "s/^\(kubernetes_master_host:\).*\(#.*\)/\1 $${kubernetes_master_host} \2/" "$1"
sed -i -e "s/^\(kubernetes_master_port:\).*\(#.*\)/\1 $${kubernetes_master_port:-8443} \2/" "$1"
sed -i -e "s/^\(master_target_pool:\).*\(#.*\).*$/\1 $${master_target_pool} \2/" "$1"

EOF
chmod a+x /usr/bin/set_iaas_routing

# Get kubo-deployment
wget https://opensourcerelease.blob.core.windows.net/alphareleases/kubo-deployment-latest.tgz
mkdir /share
tar -xvf kubo-deployment-latest.tgz -C /share
chmod -R 777 /share

# Install Terraform
wget https://releases.hashicorp.com/terraform/0.7.7/terraform_0.7.7_linux_amd64.zip
unzip terraform*.zip -d /usr/local/bin
rm /etc/motd

cd
sudo curl https://s3.amazonaws.com/bosh-cli-artifacts/bosh-cli-2.0.48-linux-amd64 -o /usr/bin/bosh
sudo chmod a+x /usr/bin/bosh
sudo curl -L https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl -o /usr/bin/kubectl
sudo chmod a+x /usr/bin/kubectl
curl -L https://github.com/cloudfoundry-incubator/credhub-cli/releases/download/1.4.0/credhub-linux-1.4.0.tgz | tar zxv
chmod a+x credhub
sudo mv credhub /usr/bin

EOT
  }
}
