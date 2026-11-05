# circuit-authentik

[![Conn3x grade](https://conn3x.org/circuits/authentik/grade.svg)](https://conn3x.org/circuits/authentik/grade)

A Conn3x circuit that runs [authentik](https://goauthentik.io), the self-hosted identity provider, on your own hosts. Your apps sign people in over OpenID Connect or SAML, and the users, sessions and audit trail stay on a machine you run.

authentik is two processes from one image: a server that answers requests and a worker that runs background tasks. The circuit runs both from the official image under Podman, as systemd services pinned by tag and digest, on the host's network and listening on loopback unless you say otherwise. You bring PostgreSQL; [circuit-postgres](https://github.com/conn3xorg/circuit-postgres) can put it on the same host. You don't need Redis or Valkey: authentik [removed that dependency](https://docs.goauthentik.io/releases/2025.10/) in 2025.10 and keeps everything in PostgreSQL.

The secret key is made on the host by the first apply. It never passes through Conn3x, so it's not in your plan, your state or your CI logs, and the passwords and the token you do pass in are ephemeral.

> **Back up `/etc/authentik/keys.env` with your database.** The key signs cookies, so a new one signs everybody out. Keep it somewhere safe, away from the database backups.

## Usage

```hcl
variable "db_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "bootstrap_password" {
  type      = string
  default   = null
  ephemeral = true
  sensitive = true
}

variable "bootstrap_token" {
  type      = string
  default   = null
  ephemeral = true
  sensitive = true
}

module "postgres" {
  source = "github.com/conn3xorg/circuit-postgres?ref=v0.2.0"

  hosts                = { auth1 = "192.168.1.50" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  users          = ["authentik"]
  user_passwords = { authentik = var.db_password }
  databases      = { authentik = "authentik" }
}

module "authentik" {
  source = "github.com/conn3xorg/circuit-authentik?ref=v0.1.2"

  depends_on = [module.postgres]

  hosts                = { auth1 = "192.168.1.50" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  public_url         = "https://auth.example.com"
  postgres_password  = var.db_password
  bootstrap_password = var.bootstrap_password
  bootstrap_token    = var.bootstrap_token
  bootstrap_email    = "you@example.com"
}
```

Then run `conn3x init` and `conn3x apply` with the secrets in the environment:

```sh
export TF_VAR_db_password="$(openssl rand -hex 24)"
export TF_VAR_bootstrap_password='...'
export TF_VAR_bootstrap_token="$(openssl rand -hex 32)"
conn3x apply
```

A second `conn3x plan` says `No changes.` Every plan needs the same values, since Conn3x checks the env files on the host against them.

authentik listens on `127.0.0.1:9000` for HTTP and `127.0.0.1:9443` for HTTPS with a self-signed certificate. Put a reverse proxy in front for TLS, such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) with `reverse_proxy 127.0.0.1:9000`, and set `public_url` to the address people type. Then sign in as `akadmin`.

The apply finishes once the server opens its port, and the worker is still applying authentik's default flows and making its certificate at that point. Give it a minute or two before you sign in, or longer on a small host. To try it on a throwaway container first, see [examples/local](examples/local).

### What was exercised, and what's only inherited

Identity servers are easy to oversell, so here's exactly where the line falls. [`examples/local/check.py`](examples/local/check.py) runs on every test host and in CI.

| Feature | Status | What that means |
| --- | --- | --- |
| Login | Exercised | The bootstrap token reaches the API as `akadmin` and a wrong one gets a 403. The bootstrap password signs in through `default-authentication-flow`, over the same API the login page uses. |
| OIDC | Exercised, partly | A provider and application are created through the API, the discovery document is served, and a client-credentials token comes back and verifies against the published JWKS. A wrong service password gets no token. The browser authorization code flow wasn't run. |
| SAML | Exercised, partly | A provider and application are created through the API, and its IdP metadata parses, with an `EntityDescriptor` and signing certificate. No service provider ever consumed an assertion. |
| SSO | Not exercised end to end | No real application signed a browser user in. The pieces above are what it's built from. |
| RBAC | Exercised, narrowly | An ordinary user's token is refused (403) when it creates a provider or lists users. No role was built and granted. |
| MFA | Inherited from upstream | The default login flow includes authentik's MFA stage, which passes when a user has no device. No authenticator was enrolled or challenged. |
| SCIM | Inherited from upstream | No SCIM provider was created and nothing was provisioned. |

### Enterprise features

Some of authentik needs a paid licence, and this circuit does nothing to change that. The same image holds them, and a licence key turns them on. Upstream's [list](https://docs.goauthentik.io/enterprise/enterprise-features/) includes Google Workspace and Microsoft Entra ID provisioning, WS-Federation, the Shared Signals Framework provider, OAuth authentication for SCIM (SCIM with a static token isn't on that list), client certificate authentication, RADIUS EAP-TLS, password history compliance, Account Lockdown, enhanced audit logging, CSV exports and privileged access management. None of them were tested here. The list changes as features mature, so check it before you plan around one.

### The bootstrap values

`bootstrap_password`, `bootstrap_token` and `bootstrap_email` only count on authentik's first start. Changing them later changes nothing in authentik, though it does rewrite the env file and restart the worker.

Upstream [warns](https://docs.goauthentik.io/install-config/automated-install/) that `AUTHENTIK_BOOTSTRAP_PASSWORD` leaves a plaintext password in the environment, and on your host it sits in `/etc/containers/env/authentik-worker.env`, mode `0600`. So take it away once it's done its job: after the first apply, stop setting `TF_VAR_bootstrap_password` and `TF_VAR_bootstrap_token`, apply again, and the file no longer has them. The token still works in authentik until you delete it there, under Directory, Tokens and App passwords. Upstream's hashed form, `AUTHENTIK_BOOTSTRAP_PASSWORD_HASH`, isn't offered yet.

Leave both null from the start and you set `akadmin`'s password yourself in the browser at `/if/flow/initial-setup/`.

### Memory

Upstream asks for [2 CPU cores and 2 GB](https://docs.goauthentik.io/install-config/install/docker-compose/), and that's what it was tested on, with PostgreSQL beside it, and it's no more than enough. Right after the first start, with its check run, about 360 MiB was still available on the Rocky Linux droplet and 455 MiB on Ubuntu, with no swap and no out-of-memory kills. After a reboot it settled at 581 and 809 MiB. There's little room for anything else on the host, and real traffic will want more.

The circuit reads each host's memory from the `conn3x_host` facts before it changes anything and stops below `min_memory_mb`. The default is 1600 MiB, not 2048, because a 2 GB host reports less: 1967 MiB on Ubuntu and 1704 MiB on Rocky Linux, as DigitalOcean droplets. Below that, lower it if you know what you're doing. A 1 GB droplet wasn't tried. The image is about 1.4 GB.

## Why containers, and why these

authentik's supported installs are containers: Compose and Kubernetes. This circuit uses Quadlet units through [circuit-podman](https://github.com/conn3xorg/circuit-podman) rather than Compose:

- **Each part is a systemd service.** `authentik-server` and `authentik-worker` start at boot, restart when they fail, and log to the journal.
- **One pin, checked.** The tag goes into each unit with a digest, and Podman pulls by the digest, so an image that's re-pushed upstream can't change what your hosts run.
- **Upgrades are a diff.** Change `authentik_version` and `image_digest`, and `conn3x plan` shows the new image. The apply restarts the services, and authentik runs its migrations as it starts. Upstream says not to skip a major release, and to back up the database first.

Two things differ from upstream's Compose file:

- **No Docker socket.** The worker runs as the image's own `authentik` user and can't start outposts for you. The outpost built into the server still handles what it handles; run others yourself.
- **The host's network.** It lets authentik reach a PostgreSQL that listens only on localhost, so the worker's health and metrics listeners move to `127.0.0.1:9001` and `9301` to stay clear of the server's. The server's metrics are on `127.0.0.1:9300`.

## What it does

On each host, in order:

1. Reads the host's facts, and stops if it has less memory than `min_memory_mb`.
2. Creates `/etc/authentik`, mode `0700`, owned by root.
3. Creates `/var/lib/authentik/data` and `/var/lib/authentik/certs`, owned by the image's user, uid 1000, inside a parent only root can enter, in case that uid is a person's account on the host.
4. If `/etc/authentik/keys.env` doesn't exist, generates `AUTHENTIK_SECRET_KEY` from `/dev/urandom`, into that file, mode `0600`. Once it exists the circuit never touches it again.
5. Through [circuit-podman](https://github.com/conn3xorg/circuit-podman) v0.1.0, installs Podman and runs two Quadlet units on the host network, `authentik-server` and `authentik-worker`, with the update check and error reporting off. `postgres_password`, the bootstrap password and token, and `environment` go to `/etc/containers/env/authentik-*.env`, mode `0600`, written from ephemeral values so they never reach the plan or state.
6. Waits up to fifteen minutes for the server to open its port.

A change to any input restarts the containers it touches.

### What it doesn't do

- It doesn't set up TLS or a reverse proxy.
- It doesn't open a port in a firewall. With the default `listen_address`, nothing outside the host can reach authentik anyway.
- It doesn't create providers, applications, users or MFA policies. Do that in authentik, or with its blueprints.
- It doesn't configure email, which password recovery needs. Add `AUTHENTIK_EMAIL__*` through `environment`.
- It doesn't back anything up. PostgreSQL, `/var/lib/authentik` and `keys.env` all matter; see [circuit-restic](https://github.com/conn3xorg/circuit-restic).
- It doesn't run more than one server. Each host in `hosts` is its own install unless you point them at the same database, which hasn't been tried.
- Deleting the module leaves Podman, the containers, `/var/lib/authentik` and `/etc/authentik` in place.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"192.168.1.50"`, or a host object such as `{ address = "192.168.1.50", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `public_url` | string | Required | The address people reach authentik at, such as `"https://auth.example.com"`. Copied to authentik's Base URL setting on the first start. |
| `postgres_password` | string | Required | Password of the PostgreSQL user, at most 99 characters. Ephemeral and sensitive. |
| `postgres` | object | `{}` | PostgreSQL 14 to 18, with `host` (`"127.0.0.1"`), `port` (`5432`), `database` (`"authentik"`), `username` (`"authentik"`) and `sslmode` (`"disable"`). Set `sslmode` for a database across a network. |
| `bootstrap_password` | string | `null` | `akadmin`'s password on the first start. Ephemeral and sensitive. |
| `bootstrap_token` | string | `null` | An API token for `akadmin` on the first start, at least 16 characters. Ephemeral and sensitive. |
| `bootstrap_email` | string | `null` | `akadmin`'s email address on the first start. |
| `listen_address` | string | `"127.0.0.1"` | Address the server listens on. `"0.0.0.0"` listens on every address. |
| `port` | number | `9000` | HTTP port. Not 9001, 9300 or 9301, which the circuit's other listeners use. |
| `https_port` | number | `9443` | HTTPS port. The same three are off limits. |
| `min_memory_mb` | number | `1600` | Memory, in MiB, a host needs before the circuit configures it. |
| `authentik_version` | string | `"2026.8.5"` | Tag of `ghcr.io/goauthentik/server`. Change `image_digest` with it. |
| `image_digest` | string | `"sha256:602227a8..."` | Digest of the image for `authentik_version`, the multi-architecture index. Find it with `skopeo inspect docker://ghcr.io/goauthentik/server:TAG`. |
| `environment` | map(string) | `{}` | More of authentik's [environment variables](https://docs.goauthentik.io/install-config/configuration/) for both containers, such as `AUTHENTIK_EMAIL__HOST`. Ephemeral and sensitive. The variables the circuit sets itself aren't allowed. |

## Outputs

| Name | Description |
| --- | --- |
| `services` | The two systemd services that run authentik. |
| `image` | The image they run, with its tag and digest. |
| `keys_file` | `/etc/authentik/keys.env`, the file to back up. |

## Requirements

Requires Conn3x v0.6.9 or later and systemd on each host, with 2 CPU cores and 2 GB of memory (see [Memory](#memory)), and room for the 1.4 GB image. The image is built for amd64 and arm64. Each host needs to reach its package mirror and `ghcr.io`, and a PostgreSQL 14 to 18. `conn3x init` fetches circuit-podman from GitHub.

## Tested on

Ubuntu 24.04 and Rocky Linux 10 with SELinux enforcing, each a 2 vCPU, 2 GB DigitalOcean droplet on amd64 with circuit-postgres on the same host. On each, the second plan was clean and [`check.py`](examples/local/check.py) passed. Both were rebooted: the services came back on their own, the same check passed, and the plan was clean. From outside the droplets, ports 9000, 9443, 9300 and 5432 didn't answer. Neither the bootstrap values nor the generated secret key appeared in `terraform.tfstate`. On Ubuntu, setting both bootstrap values to null took them out of the env file, the next plan was clean, and the token and password still worked. Neither droplet had an out-of-memory kill. Rocky's audit log had no SELinux denials.

Ubuntu 24.04, Debian 13, Rocky Linux 10 and Fedora 45 ran in local containers from Conn3x's test images, with the same check and the same look through the state, plus a restart of both services followed by the check again. The CI workflow does the same on those four, on amd64.

Upgrading from one `authentik_version` to the next hasn't been tried yet.

## License

MPL-2.0. See [LICENSE](LICENSE). authentik itself is under the MIT license, apart from its `authentik/enterprise` directory, which has its own licence, and its `website` directory, under CC BY-SA 4.0.
