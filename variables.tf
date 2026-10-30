variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "authentik_version" {
  type        = string
  default     = "2026.8.5"
  description = "Tag of the ghcr.io/goauthentik/server image, such as \"2026.8.5\". Change image_digest with it. Upstream doesn't allow skipping a major release when you upgrade."

  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]*$", var.authentik_version))
    error_message = "authentik_version must be an image tag, such as \"2026.8.5\"."
  }
}

variable "image_digest" {
  type        = string
  default     = "sha256:602227a86455d6772e3d16b7d852713c4f864f40df5df894abd1285bb53979a5"
  description = "Digest of ghcr.io/goauthentik/server for authentik_version. Podman pulls by the digest, so a tag that moves upstream can't change what runs."

  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.image_digest))
    error_message = "image_digest must be a sha256 digest, such as \"sha256:\" followed by 64 hex digits."
  }
}

variable "public_url" {
  type        = string
  description = "The address people reach authentik at, such as \"https://auth.example.com\". authentik copies it to its Base URL setting on the first start, and leaves that setting alone afterwards."

  validation {
    condition     = can(regex("^https?://[^\\s/]+(/[^\\s]*)?$", var.public_url))
    error_message = "public_url must be an http or https URL, such as \"https://auth.example.com\"."
  }
}

variable "postgres" {
  type = object({
    host     = optional(string, "127.0.0.1")
    port     = optional(number, 5432)
    database = optional(string, "authentik")
    username = optional(string, "authentik")
    sslmode  = optional(string, "disable")
  })
  default     = {}
  nullable    = false
  description = "PostgreSQL 14 to 18 to keep authentik's data in. The database and role must exist. The defaults suit one on the same host, listening on localhost; set sslmode, such as \"verify-ca\", for one across a network."

  validation {
    condition     = alltrue([for k, v in var.postgres : can(regex("^[A-Za-z0-9_.:-]+$", tostring(v)))])
    error_message = "postgres host, database, username and sslmode may use letters, digits and . _ - :."
  }
}

variable "postgres_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password of the postgres username, at most 99 characters. It reaches the host in root-only files and never the plan or state."

  validation {
    condition     = length(var.postgres_password) >= 1 && length(var.postgres_password) <= 99 && !strcontains(var.postgres_password, "\n")
    error_message = "postgres_password must be 1 to 99 characters on one line. PostgreSQL refuses longer ones."
  }
}

variable "bootstrap_password" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Password authentik gives akadmin on its first start. It reaches the host in a root-only file and never the plan or state. authentik reads it only once, so set it to null after the first apply to take it off the host."

  validation {
    condition     = var.bootstrap_password == null || (length(coalesce(var.bootstrap_password, "-")) >= 8 && !strcontains(coalesce(var.bootstrap_password, "-"), "\n"))
    error_message = "bootstrap_password must be at least 8 characters on one line."
  }
}

variable "bootstrap_token" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "API token authentik creates for akadmin on its first start. It reaches the host in a root-only file and never the plan or state. authentik reads it only once; set it to null after the first apply, and delete the token in authentik when you're done with it."

  validation {
    condition     = var.bootstrap_token == null || can(regex("^[A-Za-z0-9_-]{16,}$", coalesce(var.bootstrap_token, "-")))
    error_message = "bootstrap_token must be at least 16 letters, digits, hyphens or underscores."
  }
}

variable "bootstrap_email" {
  type        = string
  default     = null
  description = "Email address authentik gives akadmin on its first start, such as \"you@example.com\"."

  validation {
    condition     = var.bootstrap_email == null || can(regex("^[^@\\s]+@[^@\\s]+$", coalesce(var.bootstrap_email, "-")))
    error_message = "bootstrap_email must be an email address, such as \"you@example.com\"."
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address the authentik server listens on. The default keeps it on the host for a reverse proxy in front; \"0.0.0.0\" listens on every address."

  validation {
    condition     = can(cidrhost("${var.listen_address}/${strcontains(var.listen_address, ":") ? 128 : 32}", 0))
    error_message = "listen_address must be an IPv4 or IPv6 address, such as \"127.0.0.1\"."
  }
}

variable "port" {
  type        = number
  default     = 9000
  description = "Port the authentik server listens on for HTTP. 9001, 9300 and 9301 are taken by the circuit's other listeners."

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port && !contains([9001, 9300, 9301], var.port)
    error_message = "port must be a whole number from 1 to 65535, and not 9001, 9300 or 9301."
  }
}

variable "https_port" {
  type        = number
  default     = 9443
  description = "Port the authentik server listens on for HTTPS, with its self-signed certificate until you give it another."

  validation {
    condition     = var.https_port >= 1 && var.https_port <= 65535 && floor(var.https_port) == var.https_port && !contains([9001, 9300, 9301], var.https_port)
    error_message = "https_port must be a whole number from 1 to 65535, and not 9001, 9300 or 9301."
  }
}

variable "min_memory_mb" {
  type        = number
  default     = 1600
  description = "Memory, in MiB, a host needs before the circuit configures it. authentik asks for 2 GB; a 2 GB host reports less, as little as 1704 MiB on a Rocky Linux droplet."

  validation {
    condition     = var.min_memory_mb >= 0
    error_message = "min_memory_mb can't be negative."
  }
}

variable "environment" {
  type        = map(string)
  default     = {}
  ephemeral   = true
  sensitive   = true
  nullable    = false
  description = "More of authentik's environment variables for the server and worker, such as { AUTHENTIK_EMAIL__HOST = \"smtp.example.com\" }. They go in root-only files and never reach the plan or state."

  validation {
    condition     = alltrue([for k, v in var.environment : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) && !strcontains(v, "\n")])
    error_message = "environment maps variable names, such as AUTHENTIK_EMAIL__HOST, to values on one line."
  }

  validation {
    condition     = length([for k in keys(var.environment) : k if k == "AUTHENTIK_SECRET_KEY" || startswith(k, "AUTHENTIK_POSTGRESQL__") || startswith(k, "AUTHENTIK_LISTEN__") || startswith(k, "AUTHENTIK_BOOTSTRAP_")]) == 0
    error_message = "Variables the circuit sets itself aren't allowed in environment: AUTHENTIK_SECRET_KEY, AUTHENTIK_POSTGRESQL__*, AUTHENTIK_LISTEN__* and AUTHENTIK_BOOTSTRAP_*."
  }
}
