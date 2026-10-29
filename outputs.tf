output "url" {
  description = "URL the circuit checks CouchDB on, from each host itself, such as http://127.0.0.1:5984."
  value       = local.url
}

output "config_file" {
  description = "Path of the ini file the circuit writes on each host."
  value       = local.config
}
