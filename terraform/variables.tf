variable "aws_region" {
  description = "AWS Region used by the customer cell."
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS Region name."
  }
}

variable "environment" {
  description = "Cell/environment identifier used in resource names."
  type        = string
  default     = "cell-01"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,31}$", var.environment))
    error_message = "environment must be a lowercase slug between 3 and 32 characters."
  }
}

variable "customer_id" {
  description = "Opaque internal customer identifier. Do not use a real customer name."
  type        = string
  default     = "customer-001"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,31}$", var.customer_id))
    error_message = "customer_id must be an opaque lowercase slug between 3 and 32 characters."
  }
}

variable "tier" {
  description = "Commercial isolation tier for this cell."
  type        = string
  default     = "enterprise"

  validation {
    condition     = contains(["standard", "enterprise", "regulated"], var.tier)
    error_message = "tier must be standard, enterprise, or regulated."
  }
}

variable "db_username" {
  description = "RDS master username; the password is generated and managed by AWS Secrets Manager."
  type        = string
  default     = "billing_admin"
}

variable "github_repository" {
  description = "Exact GitHub owner/repository allowed to assume the CI roles."
  type        = string
  default     = "example-org/DevOps-Test"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must use the owner/repository form."
  }
}

variable "github_branch" {
  description = "Branch allowed to build and publish images."
  type        = string
  default     = "main"
}

variable "github_environment" {
  description = "Protected GitHub Environment used by the production deploy job."
  type        = string
  default     = "cell-01-production"
}

variable "k3s_api_allowed_cidrs" {
  description = "Private networks allowed to reach the K3s API. Never set 0.0.0.0/0."
  type        = list(string)
  default     = ["10.100.11.0/24"]

  validation {
    # Check both ends of every IPv4 range so a supernet that starts in RFC1918
    # space but extends into public space is rejected.
    condition = alltrue([
      for cidr in var.k3s_api_allowed_cidrs :
      can(regex(
        "^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)",
        cidrhost(cidr, 0)
      )) &&
      can(regex(
        "^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)",
        cidrhost(cidr, -1)
      ))
    ])
    error_message = "Every K3s API CIDR must be valid IPv4 and fully contained in RFC1918 private address space."
  }
}

variable "k3s_version" {
  description = "Pinned K3s version installed on the private EC2 node."
  type        = string
  default     = "v1.36.2+k3s1"
}

variable "rds_multi_az" {
  description = "Whether to deploy the RDS instance in Multi-AZ mode."
  type        = bool
  default     = true
}

variable "rds_deletion_protection" {
  description = "Protect the production RDS instance from accidental deletion."
  type        = bool
  default     = true
}
