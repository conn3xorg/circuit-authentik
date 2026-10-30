output "services" {
  description = "The systemd services that run authentik on each host."
  value       = ["authentik-server.service", "authentik-worker.service"]
}

output "image" {
  description = "The image both services run, with its tag and digest."
  value       = local.image
}

output "keys_file" {
  description = "File on each host holding the generated AUTHENTIK_SECRET_KEY. Back it up with the database."
  value       = local.keys_file
}
