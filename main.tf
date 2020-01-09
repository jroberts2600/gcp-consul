provider "google" {
  credentials = file("${var.gcp_creds}")
  project     = var.gcp_project
  region      = var.region
  zone        = var.zone
}

resource "google_compute_instance" "server_instance" {
  count        = var.server_node_count
  name         = "${var.prefix}-server${count.index + 1}"
  machine_type = var.machine_type
  boot_disk {
    initialize_params {
      image = "centos-cloud/centos-7"
    }
  }
  network_interface {
    subnetwork = google_compute_subnetwork.networks[0].self_link
    access_config {
    }
  }
  provisioner "remote-exec" {
    connection {
      user        = var.ssh_username
      host        = self.network_interface[0].access_config[0].nat_ip
      private_key = file(var.private_key)
    }
    inline = []
  }
}

locals {
  client_placement = setproduct(google_compute_subnetwork.networks[*], range(var.client_node_count))
}

resource "google_compute_instance" "client_instance" {
  count        = length(google_compute_subnetwork.networks[*]) * var.client_node_count
  name         = "${var.prefix}-client${count.index + 1}"
  machine_type = var.machine_type
  boot_disk {
    initialize_params {
      image = "centos-cloud/centos-7"
    }
  }
  network_interface {
    subnetwork = element(local.client_placement, count.index)[0].self_link
    access_config {
    }
  }
  provisioner "remote-exec" {
    connection {
      user        = var.ssh_username
      host        = self.network_interface[0].access_config[0].nat_ip
      private_key = file(var.private_key)
    }
    inline = []
  }
}

resource "google_compute_network" "vpc_network" {
  name                    = var.prefix
  auto_create_subnetworks = "false"
}

resource "google_compute_subnetwork" "networks" {
  count         = var.network_count
  name          = "${var.prefix}-network${count.index + 1}"
  ip_cidr_range = cidrsubnet(var.ip_cidr, 8, count.index)
  network       = google_compute_network.vpc_network.self_link
}

resource "google_compute_firewall" "ssh_rules" {
  name          = "${var.prefix}-ssh-rules"
  network       = google_compute_network.vpc_network.name
  source_ranges = [var.admin_source_ip]
  allow {
    protocol = "tcp"
    ports    = ["22", "8500"]
  }
}

resource "google_compute_firewall" "consul_rules" {
  name    = "${var.prefix}-consul-rules"
  network = google_compute_network.vpc_network.name
  source_ranges = google_compute_subnetwork.networks[*].ip_cidr_range
  allow {
    protocol = "tcp"
  }
}

resource "null_resource" "server_instances" {
  triggers = {
    build_number = "${timestamp()}"
  }
  provisioner "local-exec" {
    command = "ansible-playbook -u '${var.ssh_username}' -i '${tostring(join(",", google_compute_instance.server_instance[*].network_interface[0].access_config[0].nat_ip))}' --private-key '${var.private_key}' provision.yml --extra-vars consul_server=true --extra-vars node_server_ips='${tostring(format("%#v", google_compute_instance.server_instance[*].network_interface[0].network_ip))}' --skip-tags consul_license"
  }
}

resource "null_resource" "client_instances" {
  triggers = {
    build_number = "${timestamp()}"
  }
  provisioner "local-exec" {
    command = "ansible-playbook -u '${var.ssh_username}' -i '${tostring(join(",", google_compute_instance.client_instance[*].network_interface[0].access_config[0].nat_ip))}' --private-key '${var.private_key}' provision.yml --extra-vars consul_server=false --extra-vars node_server_ips='${tostring(format("%#v", google_compute_instance.server_instance[*].network_interface[0].network_ip))}' --skip-tags consul_license"
  }
  depends_on = [null_resource.server_instances]
}

resource "null_resource" "consul_license_apply" {
  triggers = {
    build_number = "${timestamp()}"
  }
  provisioner "local-exec" {
    command = "if [ ! -z '${var.consul_license_blob}' ]; then ansible-playbook -u '${var.ssh_username}' -i '${google_compute_instance.server_instance[0].network_interface[0].access_config[0].nat_ip},' --private-key '${var.private_key}' provision.yml --tags consul_license --extra-vars consul_license_blob='${var.consul_license_blob}'; fi"
  }
  depends_on = [null_resource.server_instances]
}