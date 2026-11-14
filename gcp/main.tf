# APIs are off in a fresh project; enabling them here makes the project reproducible.
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------- registry
resource "google_artifact_registry_repository" "spry" {
  repository_id = "spry"
  location      = var.region
  format        = "DOCKER"
  description   = "Backend image (the runtime stage of backend/Dockerfile, no Lambda layer)"

  # Keep the registry inside the 0.5 GB free allowance.
  cleanup_policies {
    id     = "keep-last-3"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }
  cleanup_policies {
    id     = "delete-older"
    action = "DELETE"
    condition {
      older_than = "604800s"
    }
  }

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------- database
resource "google_sql_database_instance" "spry" {
  name                = "spry-pg"
  database_version    = "POSTGRES_17"
  region              = var.region
  deletion_protection = false # a lab: terraform destroy must be able to remove it

  settings {
    edition           = "ENTERPRISE" # db-f1-micro exists only in Enterprise
    tier              = var.db_tier
    disk_type         = "PD_SSD"
    disk_size         = 10
    disk_autoresize   = false
    availability_type = "ZONAL"
    # ALWAYS = running. Set to NEVER to stop it at night (storage still bills).
    activation_policy = "ALWAYS"

    backup_configuration {
      enabled = false
    }
    ip_configuration {
      ipv4_enabled = true # reached only through the Cloud SQL connector, no authorised networks
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_sql_database" "spry" {
  name     = "spry"
  instance = google_sql_database_instance.spry.name
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_user" "spry" {
  name     = "spry"
  instance = google_sql_database_instance.spry.name
  password = random_password.db.result
}

# The whole connection string is the secret: the app reads DATABASE_URL as is.
# Through the connector the "host" is a Unix socket under /cloudsql.
resource "google_secret_manager_secret" "database_url" {
  secret_id = "spry-database-url"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "database_url" {
  secret      = google_secret_manager_secret.database_url.id
  secret_data = "postgresql+asyncpg://spry:${random_password.db.result}@/spry?host=/cloudsql/${google_sql_database_instance.spry.connection_name}"
}

# ---------------------------------------------------------------- the API
# Its own identity, not the default compute account (which starts with Editor).
resource "google_service_account" "api" {
  account_id   = "spry-api"
  display_name = "Spry API on Cloud Run"
}

resource "google_project_iam_member" "api_sql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_secret_manager_secret_iam_member" "api_reads_db_url" {
  secret_id = google_secret_manager_secret.database_url.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_cloud_run_v2_service" "api" {
  name                = "spry-api"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.api.email

    scaling {
      min_instance_count = 0 # scales to zero: an idle month costs nothing
      max_instance_count = 2 # and a runaway loop cannot open 100 instances
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.spry.connection_name]
      }
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.spry.repository_id}/backend:${var.api_image_tag}"

      ports {
        container_port = 8080 # entrypoint.sh listens on $PORT
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true # request-based billing: CPU only while a request runs
      }

      env {
        name  = "APP_ENV"
        value = "production"
      }
      env {
        name  = "DB_POOLING"
        value = "false"
      }
      env {
        name  = "CORS_ORIGINS"
        value = join(",", var.cors_origins)
      }
      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_url.secret_id
            version = "latest"
          }
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }
  }

  depends_on = [
    google_project_iam_member.api_sql,
    google_secret_manager_secret_iam_member.api_reads_db_url,
    google_secret_manager_secret_version.database_url,
  ]
}

# Public, like the Lambda function URL on AWS: Spry has no sign-in yet, so the
# API is as open on GCP as it is today. Identity Platform is the stretch goal.
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.api.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}
