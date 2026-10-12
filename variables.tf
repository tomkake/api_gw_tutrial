variable "aws_region" {
  description = "Region for this isolated PoC."
  type        = string
  default     = "ap-northeast-1"
}

variable "name_prefix" {
  description = "Prefix for new resources; a random suffix avoids existing resource names."
  type        = string
  default     = "http-api-google-poc"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,35}$", var.name_prefix))
    error_message = "Use 3–36 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "google_client_id" {
  description = "Google OAuth Web client ID (public identifier, not a client secret)."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9-]+\\.apps\\.googleusercontent\\.com$", var.google_client_id))
    error_message = "Provide the Google OAuth Web client ID ending in .apps.googleusercontent.com."
  }
}

variable "aws_account_id" {
  description = "Dedicated PoC AWS account ID; provider refuses other accounts."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Provide the 12-digit PoC AWS account ID."
  }
}

variable "allowed_email" {
  description = "Only this verified Google email may use the API; set TF_VAR_allowed_email in the ignored .env."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.allowed_email))
    error_message = "Set allowed_email to one nonempty email address."
  }
}
