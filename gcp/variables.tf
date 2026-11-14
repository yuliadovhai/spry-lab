variable "project_id" {
  description = "The GCP project (permanent, globally unique)."
  type        = string
  default     = "spry-yulia-2026"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "api_image_tag" {
  description = "Tag of the backend image in Artifact Registry (make gcp-image pushes it)."
  type        = string
  default     = "latest"
}

variable "cors_origins" {
  description = "Browser origins allowed to call the API."
  type        = list(string)
  default     = ["https://spry-yulia-2026.web.app", "http://localhost:3000"]
}

variable "db_tier" {
  description = "db-f1-micro: shared core, 0.6 GB. Runs (and bills) until stopped."
  type        = string
  default     = "db-f1-micro"
}
