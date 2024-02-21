
#depends_on = [google_project_service.service_networking]: This line specifies a dependency for a Terraform resource. 
#It means that the current resource should only be created after the specified dependency, 
#in this case, google_project_service.service_networking, has been created. 
#Dependencies are used to ensure resources are created in the correct order.

#lifecycle { create_before_destroy = true }: This block defines a lifecycle rule for a resource, 
#specifically the create_before_destroy policy. 
#When set to true, Terraform will first create a new instance of a resource before destroying the old version during updates. 
#This is useful for minimizing downtime during infrastructure changes and ensuring that a new resource is successfully created before removing the old one.
  
  




resource "google_compute_router" "nat_router" {
  project = var.project_id
  name    = "nat-router"
  region  = var.region
  network = google_compute_network.vpc.name
}

resource "google_compute_router_nat" "nat" {
  project                            = var.project_id
  name                               = "nat-config"
  router                             = google_compute_router.nat_router.name
  region                             = google_compute_router.nat_router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_compute_firewall" "allow_internal" {
  project = var.project_id
  name    = "allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  source_ranges = ["10.5.0.0/20", "10.5.16.0/20"]
}




#vpc


resource "google_compute_network" "vpc" {
  name                    = "banking-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "gke_subnet" {
  name          = "gke-subnet"
  project       = var.project_id
  ip_cidr_range = "10.5.0.0/20"
  region        = var.region
  network       = google_compute_network.vpc.name
}
resource "google_compute_subnetwork" "public_subnet" {
  project       = var.project_id
  name          = "public-subnet"
  ip_cidr_range = "10.5.16.0/20"
  region        = var.region
  network       = google_compute_network.vpc.name
}


resource "google_container_cluster" "private_cluster" {
  name       = var.name
  location   = var.region
  project    = var.project_id
  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.gke_subnet.name

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "203.0.113.0/24"
      display_name = "Corporate Network"
    }
  }

  remove_default_node_pool = true
  initial_node_count       = 1

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  ip_allocation_policy {}
}









resource "google_compute_instance" "jump_box" {
  project             = var.project_id
  name                = "jump-box"
  machine_type        = "e2-micro"
  zone                = "${var.region}-a"
  deletion_protection = false

  boot_disk {
    initialize_params {
      image = "windows-cloud/windows-2019"
      size  = 50
    }
  }

  network_interface {
    network            = google_compute_network.vpc.name
    subnetwork         = google_compute_subnetwork.public_subnet.name
    subnetwork_project = var.project_id # Explicitly specify the project
  }
  

  
  // Enable IAP-based access
  tags = ["jump-box"]
  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

resource "google_compute_firewall" "allow_iap_to_jump_box" {
  project = var.project_id
  name    = "allow-iap-to-jump-box"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22", "3389"] # Corrected spacing for consistency
  }

  target_tags = ["jump-box"]
  source_ranges = ["35.235.240.0/20"] # IP range for IAP
}



resource "google_project_service" "service_networking" {
  service = "servicenetworking.googleapis.com"
  project = var.project_id
}

resource "google_compute_global_address" "private_services_range" {
  name          = "private-services-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.self_link
  project       = var.project_id
  
  lifecycle {
    create_before_destroy = true
  }
}

resource "google_service_networking_connection" "private_vpc_connection" {

  network                 = google_compute_network.vpc.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services_range.name]
  depends_on = [google_project_service.service_networking]
  lifecycle {
    create_before_destroy = true
  }
}




resource "google_sql_database_instance" "postgres" {
  name                = "postgres-db"
  database_version    = "POSTGRES_12"
  project             = var.project_id
  region              = var.region
  deletion_protection = false
  settings {
    tier = "db-custom-1-3840"

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }
  }

    

  depends_on = [google_service_networking_connection.private_vpc_connection]
}
