terraform {
  backend "gcs" {
    bucket  = "viplav-bucket-testing-terraform"
    prefix  = "terraform/state"
  }
}

locals {
  master_instance_name = var.random_instance_name ? "private-${var.name}-${random_id.suffix[0].hex}" : var.name
}

resource "random_id" "suffix" {
  count = var.random_instance_name ? 1 : 0

  byte_length = 4
}


resource "random_id" "keyname" {

  byte_length = 1
}

resource "google_kms_key_ring" "keyring" {
  provider = google-beta
  name     = "keyring-terraform-viplav-${random_id.keyname.hex}"
  location = "us-central1"
}

resource "google_kms_key_ring_iam_member" "key_ring" {
  provider        = google-beta
  key_ring_id = google_kms_key_ring.keyring.id
  role        = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member      = "serviceAccount:service-1047837686845@gcp-sa-cloud-sql.iam.gserviceaccount.com"
}

resource "google_kms_crypto_key" "my-first-key" {
  provider        = google-beta
  name            = "key-terraform-viplav-${random_id.keyname.hex}"
  key_ring        = google_kms_key_ring.keyring.id
  rotation_period = "100000s"

  lifecycle {
    prevent_destroy = false
  }
}

resource "google_compute_network" "private_network" {
  provider = google-beta

  name = "private-network"
}

resource "google_compute_global_address" "private_ip_address" {
  provider = google-beta

  name          = "private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.private_network.id
}


resource "google_service_networking_connection" "private_vpc_connection" {
  provider = google-beta

  network                 = google_compute_network.private_network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

resource "google_sql_database_instance" "default" {
  provider            = google-beta
  project             = var.project_id
  name                = local.master_instance_name
  database_version    = var.database_version
  region              = var.region
  deletion_protection = var.deletion_protection
  encryption_key_name = google_kms_crypto_key.my-first-key.id

  settings {
    tier = var.tier
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.private_network.id
    }

    disk_size = var.disk_size
    disk_type = var.disk_type

    maintenance_window {
      day          = var.maintenance_window_day
      hour         = var.maintenance_window_hour
      update_track = var.maintenance_window_update_track
    }
  }

  lifecycle {
    ignore_changes = [
      settings[0].disk_size
    ]
  }

  /*
  timeouts {
    create = var.create_timeout
    update = var.update_timeout
    delete = var.delete_timeout
  }
*/
  depends_on  = [google_kms_crypto_key.my-first-key,google_service_networking_connection.private_vpc_connection]
  #depends_on  = [google_service_networking_connection.private_vpc_connection]
}

resource "google_sql_database" "default" {
  provider = google-beta
  count      = var.enable_default_db ? 1 : 0
  name       = var.db_name
  project    = var.project_id
  instance   = google_sql_database_instance.default.name
  charset    = var.db_charset
  collation  = var.db_collation
  depends_on = [google_sql_database_instance.default]
}

resource "random_id" "user-password" {
  keepers = {
    name = google_sql_database_instance.default.name
  }

  byte_length = 8
  depends_on  = [google_sql_database_instance.default]
}

resource "google_sql_user" "default" {
  provider = google-beta
  count      = var.enable_default_user ? 1 : 0
  name       = var.user_name
  project    = var.project_id
  instance   = google_sql_database_instance.default.name
  host       = var.user_host
  password   = var.user_password == "" ? random_id.user-password.hex : var.user_password
  depends_on = [google_sql_database_instance.default]
}
