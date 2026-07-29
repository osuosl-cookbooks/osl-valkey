# Three-node valkey + sentinel cluster: valkey1 is the seeded primary,
# valkey2/valkey3 replicate from it, and every node runs a sentinel so
# the quorum is 2 of 3. Replication and sentinel gossip run over the
# private network below; the public port on each node only carries ssh
# for the bootstrap and the inspec runner.
resource "openstack_networking_network_v2" "valkey_network" {
    name           = "valkey_network"
    admin_state_up = "true"
}

resource "openstack_networking_subnet_v2" "valkey_subnet" {
    network_id  = openstack_networking_network_v2.valkey_network.id
    cidr        = "10.1.0.0/24"
    enable_dhcp = "false"
    no_gateway  = "true"
}

# Static addresses so the chef run lists can name the primary without
# any discovery: valkey1 .11, valkey2 .12, valkey3 .13.
resource "openstack_networking_port_v2" "valkey1_port" {
    network_id            = openstack_networking_network_v2.valkey_network.id
    admin_state_up        = "true"
    port_security_enabled = "false"
    fixed_ip {
        subnet_id  = openstack_networking_subnet_v2.valkey_subnet.id
        ip_address = "10.1.0.11"
    }
}

resource "openstack_networking_port_v2" "valkey2_port" {
    network_id            = openstack_networking_network_v2.valkey_network.id
    admin_state_up        = "true"
    port_security_enabled = "false"
    fixed_ip {
        subnet_id  = openstack_networking_subnet_v2.valkey_subnet.id
        ip_address = "10.1.0.12"
    }
}

resource "openstack_networking_port_v2" "valkey3_port" {
    network_id            = openstack_networking_network_v2.valkey_network.id
    admin_state_up        = "true"
    port_security_enabled = "false"
    fixed_ip {
        subnet_id  = openstack_networking_subnet_v2.valkey_subnet.id
        ip_address = "10.1.0.13"
    }
}

resource "openstack_networking_port_v2" "chef_zero" {
    name           = "chef_zero"
    admin_state_up = true
    network_id     = data.openstack_networking_network_v2.public.id
}

resource "openstack_compute_instance_v2" "chef_zero" {
    name            = "chef-zero"
    image_name      = var.docker_image
    flavor_name     = "m2.local.2c3m10d"
    key_pair        = var.ssh_key_name
    security_groups = ["default"]
    connection {
        user = var.ssh_user_name
        host = openstack_networking_port_v2.chef_zero.all_fixed_ips.0
    }
    network {
        port = openstack_networking_port_v2.chef_zero.id
    }
    provisioner "remote-exec" {
        inline = [
            "until [ -S /var/run/docker.sock ] ; do sleep 1 && echo 'docker not started...' ; done",
            "sudo docker run -d -p 8889:8889 --name chef-zero osuosl/chef-zero"
        ]
    }
}

# Re-upload cookbooks and roles on every apply, so a local edit is
# picked up without recreating chef_zero. As a provisioner on the
# instance above this would run only at creation, and every converge
# after the first would silently test the code as it was that day.
resource "null_resource" "knife_upload" {
    triggers = {
        always_run = timestamp()
    }

    provisioner "local-exec" {
        command = "rake knife_upload"
        environment = {
            CHEF_SERVER = "${openstack_compute_instance_v2.chef_zero.network.0.fixed_ip_v4}"
        }
    }

    depends_on = [
        openstack_compute_instance_v2.chef_zero,
    ]
}

resource "openstack_networking_port_v2" "valkey1_server" {
    name           = "valkey1_server"
    admin_state_up = true
    network_id     = data.openstack_networking_network_v2.public.id
}

resource "openstack_compute_instance_v2" "valkey1" {
    name            = "valkey1"
    image_name      = var.os_image
    flavor_name     = "m2.local.2c3m10d"
    key_pair        = var.ssh_key_name
    security_groups = ["default"]
    connection {
        user = var.ssh_user_name
        host = openstack_networking_port_v2.valkey1_server.all_fixed_ips.0
    }
    network {
        port = openstack_networking_port_v2.valkey1_server.id
    }
    network {
        port = openstack_networking_port_v2.valkey1_port.id
    }
    provisioner "remote-exec" {
        inline = ["echo online"]
    }
}

# The primary converges first so the replicas have something to sync
# from on their very first run.
resource "null_resource" "valkey1" {
    triggers = {
        instance_id = openstack_compute_instance_v2.valkey1.id
    }

    provisioner "local-exec" {
        command = <<-EOF
            knife bootstrap -c test/chef-config/knife.rb \
                ${var.ssh_user_name}@${openstack_compute_instance_v2.valkey1.network.0.fixed_ip_v4} \
                -y -N valkey1 --sudo --bootstrap-version ${var.chef_version} \
                -r 'role[valkey_cluster]'
            EOF
        environment = {
            CHEF_SERVER = "${openstack_compute_instance_v2.chef_zero.network.0.fixed_ip_v4}"
        }
    }

    depends_on = [
        null_resource.knife_upload,
        openstack_compute_instance_v2.valkey1
    ]
}

resource "openstack_networking_port_v2" "valkey2_server" {
    name           = "valkey2_server"
    admin_state_up = true
    network_id     = data.openstack_networking_network_v2.public.id
}

resource "openstack_compute_instance_v2" "valkey2" {
    name            = "valkey2"
    image_name      = var.os_image
    flavor_name     = "m2.local.2c3m10d"
    key_pair        = var.ssh_key_name
    security_groups = ["default"]
    connection {
        user = var.ssh_user_name
        host = openstack_networking_port_v2.valkey2_server.all_fixed_ips.0
    }
    network {
        port = openstack_networking_port_v2.valkey2_server.id
    }
    network {
        port = openstack_networking_port_v2.valkey2_port.id
    }
    provisioner "remote-exec" {
        inline = ["echo online"]
    }
}

resource "null_resource" "valkey2" {
    triggers = {
        instance_id = openstack_compute_instance_v2.valkey2.id
    }

    provisioner "local-exec" {
        command = <<-EOF
            knife bootstrap -c test/chef-config/knife.rb \
                ${var.ssh_user_name}@${openstack_compute_instance_v2.valkey2.network.0.fixed_ip_v4} \
                -y -N valkey2 --sudo --bootstrap-version ${var.chef_version} \
                -r 'role[valkey_cluster]'
            EOF
        environment = {
            CHEF_SERVER = "${openstack_compute_instance_v2.chef_zero.network.0.fixed_ip_v4}"
        }
    }

    depends_on = [
        openstack_compute_instance_v2.valkey2,
        null_resource.valkey1
    ]
}

resource "openstack_networking_port_v2" "valkey3_server" {
    name           = "valkey3_server"
    admin_state_up = true
    network_id     = data.openstack_networking_network_v2.public.id
}

resource "openstack_compute_instance_v2" "valkey3" {
    name            = "valkey3"
    image_name      = var.os_image
    flavor_name     = "m2.local.2c3m10d"
    key_pair        = var.ssh_key_name
    security_groups = ["default"]
    connection {
        user = var.ssh_user_name
        host = openstack_networking_port_v2.valkey3_server.all_fixed_ips.0
    }
    network {
        port = openstack_networking_port_v2.valkey3_server.id
    }
    network {
        port = openstack_networking_port_v2.valkey3_port.id
    }
    provisioner "remote-exec" {
        inline = ["echo online"]
    }
}

resource "null_resource" "valkey3" {
    triggers = {
        instance_id = openstack_compute_instance_v2.valkey3.id
    }

    provisioner "local-exec" {
        command = <<-EOF
            knife bootstrap -c test/chef-config/knife.rb \
                ${var.ssh_user_name}@${openstack_compute_instance_v2.valkey3.network.0.fixed_ip_v4} \
                -y -N valkey3 --sudo --bootstrap-version ${var.chef_version} \
                -r 'role[valkey_cluster]'
            EOF
        environment = {
            CHEF_SERVER = "${openstack_compute_instance_v2.chef_zero.network.0.fixed_ip_v4}"
        }
    }

    depends_on = [
        openstack_compute_instance_v2.valkey3,
        null_resource.valkey2
    ]
}
