resource "google_project_service" "compute" {
  count = var.enable_apis ? 1 : 0

  project            = var.gcp_project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_network" "main" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "main" {
  name          = "${var.name_prefix}-subnet"
  ip_cidr_range = var.gcp_subnet_cidr
  region        = var.gcp_region
  network       = google_compute_network.main.id
}

# Unico ingress activo por defecto: SQL Server desde las subnets privadas de AWS.
resource "google_compute_firewall" "allow_sqlserver_from_aws" {
  name      = "allow-sqlserver-from-aws"
  network   = google_compute_network.main.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = [tostring(var.sqlserver_port)]
  }

  source_ranges = var.aws_private_subnet_cidrs
  target_tags   = ["demo-sqlserver-onprem"]
}

resource "google_compute_firewall" "allow_iap_ssh" {
  count = var.enable_iap_ssh ? 1 : 0

  name      = "allow-iap-ssh"
  network   = google_compute_network.main.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["demo-sqlserver-onprem"]
}
