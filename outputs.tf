output "dynamodb_table_name" {
  description = "Tabla DynamoDB de origen."
  value       = aws_dynamodb_table.demo.name
}

output "control_table_name" {
  description = "Tabla de control de sincronizacion."
  value       = aws_dynamodb_table.control.name
}

output "lambda_function_name" {
  description = "Funcion Lambda de sincronizacion."
  value       = aws_lambda_function.sync.function_name
}

output "secret_name" {
  description = "Secreto con las credenciales de SQL Server (el contenido no se expone)."
  value       = aws_secretsmanager_secret.sqlserver.name
}

output "streams_dlq_name" {
  description = "Cola DLQ del stream (null si enable_streams_sync = false)."
  value       = one(aws_sqs_queue.streams_dlq[*].name)
}

output "sqlserver_external_ip" {
  description = "IP externa efimera de la VM (null si assign_public_ip = false)."
  value       = try(google_compute_instance.sqlserver.network_interface[0].access_config[0].nat_ip, null)
}

output "sqlserver_internal_ip" {
  description = "IP interna de la VM; es el host que usa la Lambda a traves de la VPN."
  value       = google_compute_address.sqlserver_internal.address
}

output "vpn_connection_id" {
  description = "ID de la conexion VPN de AWS (2 tuneles)."
  value       = aws_vpn_connection.this.id
}

output "aws_vpn_public_ips" {
  description = "Las 2 IPs publicas de los tuneles del lado AWS (tunel 1 y tunel 2)."
  value = [
    aws_vpn_connection.this.tunnel1_address,
    aws_vpn_connection.this.tunnel2_address,
  ]
}

output "gcp_ha_vpn_gateway_ips" {
  description = "IPs de las 2 interfaces del HA VPN gateway de GCP (solo se usa la interfaz 0)."
  value       = [for i in google_compute_ha_vpn_gateway.this.vpn_interfaces : i.ip_address]
}

output "suggested_commands" {
  description = "Comandos sugeridos para la demo."
  value       = "./scripts/check-vpn.sh  # estado de tuneles y BGP\n./scripts/full-load.sh  # carga inicial DynamoDB -> SQL Server"
}
