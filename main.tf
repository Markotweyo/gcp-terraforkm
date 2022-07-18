// Configure the terraform provider
terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "3.5.0"
    }
  }
}

// Create VPC
resource "google_compute_network" "vpc" {
 name                    = "${var.name}-vpc"
 auto_create_subnetworks = "false"
}

// Create Subnet
resource "google_compute_subnetwork" "subnet" {
 name          = "${var.name}-subnet"
 ip_cidr_range = "${var.subnet_cidr}"
 network       = "${var.name}-vpc"
 depends_on    = [google_compute_network.vpc]
 region        = "${var.region}"
 
}
// VPC firewall configuration
resource "google_compute_firewall" "firewall" {
  name    = "${var.name}-firewall"
  network = "${google_compute_network.vpc.name}"

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["22", "443", "8200", "1000-4000"]
  }

  source_ranges = ["0.0.0.0/0"]
  source_tags=["web"]
}

//Instance

locals {
	master_instance_virtual_machines = {
   "master" = { zone = "us-east4-a" },
   "master-backup" = {zone = "us-east4-b" }
 }
}
resource "google_compute_instance" "vm_instance" {
  for_each=local.master_instance_virtual_machines
  name         = each.key
  machine_type = "n2-standard-4"
  zone			=each.value.zone
  tags         = ["web","master-tag"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-9"
    }
  }

  network_interface {
    network = google_compute_network.vpc.name
	subnetwork = google_compute_subnetwork.subnet.self_link
    # access_config {
    # }
  }
}

//Creating Autoscaller resource main

resource "google_compute_region_autoscaler" "default" {
  provider = google-beta
  name     = "my-auto-scaler"
  region     = "us-east4"
  target   = google_compute_region_instance_group_manager.default.id

  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 3
    cooldown_period = 60

    metric {
      name                       = "pubsub.googleapis.com/subscription/num_undelivered_messages"
      filter                     = "resource.type = pubsub_subscription AND resource.label.subscription_id = our-subscription"
      single_instance_assignment = 65535
    }
	cpu_utilization {
      target = 0.7
    }
  }
}


//Creating Instance Template
resource "google_compute_instance_template" "default" {
  provider = google-beta
  name           = "my-instance-template"
  machine_type   = "e2-standard-4"
  can_ip_forward = false

  tags = ["foo", "bar"]

  disk {
    source_image = data.google_compute_image.debian_9.id
  }

  network_interface {
    network = google_compute_network.vpc.name
	subnetwork = google_compute_subnetwork.subnet.self_link
  }

  metadata = {
    foo = "bar"
  }

  
}

resource "google_compute_target_pool" "default" {
  provider = google-beta
  name = "my-target-pool"
}

resource "google_compute_health_check" "autohealing" {
  name                = "autohealing-health-check"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 10 # 50 seconds

  http_health_check {
    request_path = "/healthz"
    port         = "8080"
  }
}
//Creating compte Instance google_compute_instance_group_manager
resource "google_compute_region_instance_group_manager" "default" {
  provider = google-beta
  name = "main-my-igm"
  region="us-east4"
  distribution_policy_zones=["us-east4-a", "us-east4-b"]

  version {
    instance_template = google_compute_instance_template.default.id
    name              = "primary"
  }

  target_pools       = [google_compute_target_pool.default.id]
  base_instance_name = "autoscaler-sample"

  named_port {
    name = "http"
    port = "8080"
  }
  named_port {
    name = "https"
    port = "8443"
  }
   named_port {
    name = "ssh"
    port = "22"
  }
  auto_healing_policies {
    health_check      = google_compute_health_check.autohealing.id
    initial_delay_sec = 300
  }
}

data "google_compute_image" "debian_9" {
  provider = google-beta
  family  = "debian-9"
  project = "debian-cloud"
}


resource "google_compute_backend_service" "worker_service" {
  name      = "worker-service"
  port_name = "https"
  protocol  = "HTTPS"

#   backend {
#     group = "${google_compute_instance_group_manager.default.self_link}"
#   }

  health_checks = [
    google_compute_https_health_check.worker_health.id,
  ]
}

resource "google_compute_https_health_check" "worker_health" {
  name         = "worker-health"
  request_path = "/health_check"
  check_interval_sec = 1
  timeout_sec        = 1
}