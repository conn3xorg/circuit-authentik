locals {
  image = "ghcr.io/goauthentik/server:${var.authentik_version}@${var.image_digest}"

  dir       = "/etc/authentik"
  keys_file = "${local.dir}/keys.env"

  # What the server and the worker both need, none of it secret. The secrets
  # come from keys.env and from circuit-podman's env files. The update check
  # stays off because the circuit pins the image, and error reporting off
  # because it would send data to sentry.io.
  common_env = {
    AUTHENTIK_POSTGRESQL__HOST         = var.postgres.host
    AUTHENTIK_POSTGRESQL__PORT         = tostring(var.postgres.port)
    AUTHENTIK_POSTGRESQL__NAME         = var.postgres.database
    AUTHENTIK_POSTGRESQL__USER         = var.postgres.username
    AUTHENTIK_POSTGRESQL__SSLMODE      = var.postgres.sslmode
    AUTHENTIK_WEB__BASE_URL            = var.public_url
    AUTHENTIK_DISABLE_UPDATE_CHECK     = "true"
    AUTHENTIK_ERROR_REPORTING__ENABLED = "false"
  }

  listen_host = strcontains(var.listen_address, ":") ? "[${var.listen_address}]" : var.listen_address

  # Upstream's Compose file shm_size. Set through PodmanArgs because Ubuntu
  # 24.04's Podman 4.9 doesn't know Quadlet's ShmSize.
  shm = "PodmanArgs=--shm-size=512m"

  # Certificates in /certs get imported by the worker; /data holds uploaded
  # files, which both processes read. Directories rather than named volumes:
  # two containers starting together race to create a named volume, and one
  # of them fails. z is SELinux's label for a mount that containers share.
  state_dir = "/var/lib/authentik"
  volumes   = ["${local.state_dir}/data:/data:z", "${local.state_dir}/certs:/certs:z"]
}

# Facts give each host's memory. authentik asks for 2 CPU cores and 2 GB.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = self.memory_mb >= var.min_memory_mb
      error_message = "Host ${each.key} has ${self.memory_mb} MiB of memory. authentik asks for at least 2 GB. Set min_memory_mb lower to go ahead anyway."
    }
  }
}

# The secret key is generated on the host by the first apply and never
# passes through Conn3x, so it's in neither the plan nor state. creates keeps
# it from being replaced, which would sign everyone out.
circuit "keys" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "dir" {
    depends_on = [data.conn3x_host.facts]
    directory {
      path  = local.dir
      owner = "root"
      group = "root"
      mode  = "0700"
    }
  }

  # The image's authentik user is uid 1000. A command, since the directory
  # step takes user names and the host has no such user.
  step "state" {
    command {
      command = "install -d -m 0755 ${local.state_dir} && install -d -o 1000 -g 1000 -m 0750 ${local.state_dir}/data ${local.state_dir}/certs"
      creates = "${local.state_dir}/certs"
    }
  }

  step "generate" {
    command {
      command = <<-EOT
        set -eu
        umask 077
        cd ${local.dir}
        printf 'AUTHENTIK_SECRET_KEY=%s\n' "$(head -c 60 /dev/urandom | od -An -tx1 | tr -d ' \n')" > keys.env.new
        mv keys.env.new keys.env
      EOT
      creates = local.keys_file
    }
  }
}

# Two containers from the one official image, each a Quadlet unit on the
# host's network, so authentik reaches a PostgreSQL that listens only on
# localhost. Sharing that network means they can't share ports, so the worker
# moves its health and metrics listeners, which upstream's Compose file keeps
# apart with a bridge. There's no Docker socket: the worker runs as the
# image's own user, and can't start outposts by itself.
module "podman" {
  source = "github.com/conn3xorg/circuit-podman?ref=v0.1.0"

  depends_on = [conn3x_command.keys__generate, conn3x_command.keys__state]

  hosts                = var.hosts
  ssh_user             = var.ssh_user
  ssh_port             = var.ssh_port
  ssh_private_key_file = var.ssh_private_key_file
  ssh_known_hosts_file = var.ssh_known_hosts_file
  ssh_become           = var.ssh_become

  containers = {
    authentik-server = {
      image   = local.image
      volumes = local.volumes
      environment = merge(local.common_env, {
        AUTHENTIK_LISTEN__HTTP    = "${local.listen_host}:${var.port}"
        AUTHENTIK_LISTEN__HTTPS   = "${local.listen_host}:${var.https_port}"
        AUTHENTIK_LISTEN__METRICS = "127.0.0.1:9300"
      })
      extra = ["Network=host", local.shm, "EnvironmentFile=${local.keys_file}", "Exec=server"]
    }

    # upstream reads the AUTHENTIK_BOOTSTRAP_* variables on the worker only.
    authentik-worker = {
      image   = local.image
      volumes = local.volumes
      environment = merge(local.common_env, {
        AUTHENTIK_LISTEN__HTTP    = "127.0.0.1:9001"
        AUTHENTIK_LISTEN__METRICS = "127.0.0.1:9301"
        }, var.bootstrap_email == null ? {} : {
        AUTHENTIK_BOOTSTRAP_EMAIL = var.bootstrap_email
      })
      extra = ["Network=host", local.shm, "EnvironmentFile=${local.keys_file}", "Exec=worker"]
    }
  }
  secrets = {
    authentik-server = merge(var.environment, {
      AUTHENTIK_POSTGRESQL__PASSWORD = var.postgres_password
    })
    authentik-worker = merge(var.environment, {
      AUTHENTIK_POSTGRESQL__PASSWORD = var.postgres_password
      }, var.bootstrap_password == null ? {} : {
      AUTHENTIK_BOOTSTRAP_PASSWORD = var.bootstrap_password
      }, var.bootstrap_token == null ? {} : {
      AUTHENTIK_BOOTSTRAP_TOKEN = var.bootstrap_token
    })
  }
}

circuit "authentik" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # On a first start the server pulls about 1 GB and waits for its database
  # migrations before it listens.
  step "ready" {
    depends_on = [module.podman]
    wait_for {
      port    = var.port
      timeout = "15m"
    }
  }
}
