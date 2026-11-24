locals {
  gcp_zone = "${var.gcp_region}-${var.gcp_zone_suffix}"
}

# Sin comillas, $ ni \ para no romper shell ni T-SQL.
resource "random_password" "sa" {
  length           = 24
  min_upper        = 4
  min_lower        = 4
  min_numeric      = 4
  special          = true
  override_special = "_-#%*"
}

resource "random_password" "app" {
  length           = 24
  min_upper        = 4
  min_lower        = 4
  min_numeric      = 4
  special          = true
  override_special = "_-#%*"
}

data "google_compute_image" "cos" {
  family  = "cos-stable"
  project = "cos-cloud"
}

resource "google_compute_address" "sqlserver_internal" {
  name         = "${var.name_prefix}-sqlserver-ip"
  region       = var.gcp_region
  subnetwork   = google_compute_subnetwork.main.id
  address_type = "INTERNAL"
}

resource "google_compute_instance" "sqlserver" {
  name         = "${var.name_prefix}-sqlserver-onprem"
  machine_type = var.gcp_machine_type
  zone         = local.gcp_zone
  tags         = ["demo-sqlserver-onprem"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.cos.self_link
      size  = var.gcp_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    network_ip = google_compute_address.sqlserver_internal.address

    # IP externa efimera solo para el docker pull; el firewall no la expone.
    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content {}
    }
  }

  metadata = {
    sa-password    = random_password.sa.result
    app-password   = random_password.app.result
    mssql-image    = var.mssql_image
    mssql-database = var.sqlserver_database
    mssql-app-user = var.sqlserver_app_user
    init-sql       = file("${path.module}/gcp/init.sql")
    startup-script = file("${path.module}/gcp/startup-script.sh")
  }

  service_account {
    scopes = []
  }
}
