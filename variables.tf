variable "gcp_project_id" {
  description = "ID del proyecto de GCP donde se crean la red, la VPN y la VM."
  type        = string

  validation {
    condition     = var.gcp_project_id != "your-gcp-project-id"
    error_message = "Define gcp_project_id con el ID real de tu proyecto de GCP (sigue con el valor placeholder)."
  }
}

variable "aws_region" {
  description = "Region de AWS."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Perfil de AWS CLI a usar. null usa la cadena de credenciales por defecto."
  type        = string
  default     = null
}

variable "aws_allowed_account_ids" {
  description = "Lista de cuentas AWS permitidas (proteccion contra aplicar en la cuenta equivocada). Vacia = sin restriccion."
  type        = list(string)
  default     = []
}

variable "gcp_region" {
  description = "Region de GCP."
  type        = string
  default     = "us-east4"
}

variable "gcp_zone_suffix" {
  description = "Sufijo de la zona de GCP (la zona final es <region>-<sufijo>)."
  type        = string
  default     = "a"
}

variable "name_prefix" {
  description = "Prefijo para nombrar los recursos del demo."
  type        = string
  default     = "demo"
}

variable "aws_vpc_cidr" {
  description = "CIDR de la VPC de AWS."
  type        = string
  default     = "10.20.0.0/16"
}

variable "aws_private_subnet_cidrs" {
  description = "CIDRs de las 2 subnets privadas de AWS (una por AZ)."
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "gcp_subnet_cidr" {
  description = "CIDR de la subnet de GCP donde vive la VM con SQL Server."
  type        = string
  default     = "10.10.1.0/24"
}

variable "aws_target_gateway" {
  description = "Gateway de AWS que termina la VPN: 'vgw' (Virtual Private Gateway, por defecto) o 'tgw' (Transit Gateway)."
  type        = string
  default     = "vgw"

  validation {
    condition     = contains(["vgw", "tgw"], var.aws_target_gateway)
    error_message = "aws_target_gateway debe ser 'vgw' o 'tgw'."
  }
}

variable "aws_bgp_asn" {
  description = "ASN del lado AWS (amazon_side_asn del VGW/TGW)."
  type        = number
  default     = 64512
}

variable "gcp_bgp_asn" {
  description = "ASN del Cloud Router de GCP (rango privado)."
  type        = number
  default     = 65010

  validation {
    condition = (
      (var.gcp_bgp_asn >= 64512 && var.gcp_bgp_asn <= 65534) ||
      (var.gcp_bgp_asn >= 4200000000 && var.gcp_bgp_asn <= 4294967294)
    )
    error_message = "gcp_bgp_asn debe estar en un rango privado: 64512-65534 o 4200000000-4294967294."
  }
}

variable "gcp_machine_type" {
  description = "Tipo de maquina de la VM (SQL Server necesita al menos 2 GB de RAM)."
  type        = string
  default     = "e2-medium"
}

variable "gcp_disk_size_gb" {
  description = "Tamano del disco de arranque en GB."
  type        = number
  default     = 30
}

variable "assign_public_ip" {
  description = "Asigna IP externa efimera a la VM solo para que pueda descargar la imagen de Docker. El firewall no expone nada mas que 1433 desde AWS."
  type        = bool
  default     = true
}

variable "enable_iap_ssh" {
  description = "Crea una regla de firewall para SSH por IAP (35.235.240.0/20, tcp:22)."
  type        = bool
  default     = false
}

variable "mssql_image" {
  description = "Imagen de Docker de SQL Server."
  type        = string
  default     = "mcr.microsoft.com/mssql/server:2022-latest"
}

variable "sqlserver_port" {
  description = "Puerto de SQL Server."
  type        = number
  default     = 1433
}

variable "sqlserver_database" {
  description = "Nombre de la base de datos del demo."
  type        = string
  default     = "demo_db"
}

variable "sqlserver_app_user" {
  description = "Usuario de aplicacion (db_datareader/db_datawriter) para la Lambda."
  type        = string
  default     = "demo_app"
}

variable "enable_apis" {
  description = "Habilita las APIs de GCP necesarias (compute)."
  type        = bool
  default     = true
}

# ---------- Plano de datos AWS (FEAT-002) ----------

variable "dynamodb_table_name" {
  description = "Nombre de la tabla DynamoDB de origen."
  type        = string
  default     = "demo-merchants-table"
}

variable "control_table_name" {
  description = "Nombre de la tabla de control de sincronizacion."
  type        = string
  default     = "demo-sync-control"
}

variable "secret_name" {
  description = "Nombre del secreto en Secrets Manager con las credenciales de SQL Server."
  type        = string
  default     = "demo-sqlserver-onprem"
}

variable "lambda_function_name" {
  description = "Nombre de la funcion Lambda de sincronizacion."
  type        = string
  default     = "demo-dynamodb-sqlserver-sync"
}

variable "sqlserver_target_table" {
  description = "Tabla destino en SQL Server con formato esquema.tabla."
  type        = string
  default     = "dbo.merchants"

  validation {
    condition     = can(regex("^[A-Za-z_][A-Za-z0-9_]*\\.[A-Za-z_][A-Za-z0-9_]*$", var.sqlserver_target_table))
    error_message = "sqlserver_target_table debe tener el formato esquema.tabla (por ejemplo dbo.merchants)."
  }
}

variable "lambda_timeout" {
  description = "Timeout de la Lambda en segundos."
  type        = number
  default     = 120
}

variable "lambda_memory_size" {
  description = "Memoria de la Lambda en MB."
  type        = number
  default     = 256
}

variable "scan_page_size" {
  description = "Items por pagina en el full load (chico para que se vea paginado)."
  type        = number
  default     = 25
}

variable "time_safety_margin_ms" {
  description = "Margen de seguridad en ms antes del timeout para cortar el full load y devolver checkpoint."
  type        = number
  default     = 15000
}

variable "app_env" {
  description = "Etiqueta de ambiente que recibe la Lambda."
  type        = string
  default     = "demo"
}

variable "enable_streams_sync" {
  description = "Activa la sincronizacion por DynamoDB Streams (DLQ, permisos y event source mapping)."
  type        = bool
  default     = false
}

variable "streams_batch_size" {
  description = "Tamano de batch del event source mapping."
  type        = number
  default     = 10
}

variable "streams_starting_position" {
  description = "Posicion inicial del stream (LATEST o TRIM_HORIZON)."
  type        = string
  default     = "LATEST"

  validation {
    condition     = contains(["LATEST", "TRIM_HORIZON"], var.streams_starting_position)
    error_message = "streams_starting_position debe ser LATEST o TRIM_HORIZON."
  }
}

variable "streams_maximum_retry_attempts" {
  description = "Reintentos maximos del event source mapping antes de enviar a la DLQ."
  type        = number
  default     = 3
}

variable "dlq_message_retention_seconds" {
  description = "Retencion de mensajes de la DLQ en segundos (default 14 dias)."
  type        = number
  default     = 1209600
}

variable "tags" {
  description = "Tags adicionales para los recursos de AWS."
  type        = map(string)
  default     = {}
}
