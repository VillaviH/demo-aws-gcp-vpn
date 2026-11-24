data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  use_vgw = var.aws_target_gateway == "vgw"
  use_tgw = var.aws_target_gateway == "tgw"
}

resource "aws_vpc" "main" {
  cidr_block           = var.aws_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# Subnets privadas (sin IGW ni NAT): solo hablan con GCP por la VPN.
resource "aws_subnet" "private" {
  count = length(var.aws_private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.aws_private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.name_prefix}-private-${count.index + 1}"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------- Rama VGW (por defecto) ----------
resource "aws_vpn_gateway" "this" {
  count = local.use_vgw ? 1 : 0

  amazon_side_asn = var.aws_bgp_asn

  tags = {
    Name = "${var.name_prefix}-vgw"
  }
}

resource "aws_vpn_gateway_attachment" "this" {
  count = local.use_vgw ? 1 : 0

  vpc_id         = aws_vpc.main.id
  vpn_gateway_id = aws_vpn_gateway.this[0].id
}

resource "aws_vpn_gateway_route_propagation" "private" {
  count = local.use_vgw ? 1 : 0

  vpn_gateway_id = aws_vpn_gateway.this[0].id
  route_table_id = aws_route_table.private.id

  depends_on = [aws_vpn_gateway_attachment.this]
}

# ---------- Rama TGW ----------
resource "aws_ec2_transit_gateway" "this" {
  count = local.use_tgw ? 1 : 0

  amazon_side_asn                 = var.aws_bgp_asn
  vpn_ecmp_support                = "enable"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"

  tags = {
    Name = "${var.name_prefix}-tgw"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = local.use_tgw ? 1 : 0

  transit_gateway_id = aws_ec2_transit_gateway.this[0].id
  vpc_id             = aws_vpc.main.id
  subnet_ids         = aws_subnet.private[*].id

  tags = {
    Name = "${var.name_prefix}-tgw-attachment"
  }
}

resource "aws_route" "to_gcp_via_tgw" {
  count = local.use_tgw ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = var.gcp_subnet_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this[0].id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

locals {
  vpn_target = {
    vpn_gateway_id     = local.use_vgw ? aws_vpn_gateway.this[0].id : null
    transit_gateway_id = local.use_tgw ? aws_ec2_transit_gateway.this[0].id : null
  }
}

# ---------- VPC endpoints (sin NAT, la Lambda llega a los servicios por aqui) ----------
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.tags, { Name = "${var.name_prefix}-dynamodb-endpoint" })
}

resource "aws_security_group" "secretsmanager_endpoint" {
  name        = "${var.name_prefix}-secretsmanager-endpoint"
  description = "Endpoint de Secrets Manager: 443 solo desde la Lambda"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-secretsmanager-endpoint-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "secretsmanager_from_lambda" {
  security_group_id            = aws_security_group.secretsmanager_endpoint.id
  description                  = "HTTPS desde la Lambda"
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# Una sola subnet para abaratar el endpoint de interfaz.
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private[0].id]
  security_group_ids  = [aws_security_group.secretsmanager_endpoint.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-secretsmanager-endpoint" })
}

# ---------- SG de la Lambda: sin ingress, sin 0.0.0.0/0 ----------
resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-lambda"
  description = "Lambda de sync: solo egress a SQL Server (VPN) y a los endpoints"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-lambda-sg" })
}

resource "aws_vpc_security_group_egress_rule" "lambda_sqlserver" {
  security_group_id = aws_security_group.lambda.id
  description       = "SQL Server en GCP via VPN"
  cidr_ipv4         = var.gcp_subnet_cidr
  ip_protocol       = "tcp"
  from_port         = var.sqlserver_port
  to_port           = var.sqlserver_port
}

resource "aws_vpc_security_group_egress_rule" "lambda_dynamodb" {
  security_group_id = aws_security_group.lambda.id
  description       = "HTTPS al endpoint Gateway de DynamoDB"
  prefix_list_id    = aws_vpc_endpoint.dynamodb.prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "lambda_secretsmanager" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "HTTPS al endpoint de Secrets Manager"
  referenced_security_group_id = aws_security_group.secretsmanager_endpoint.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
