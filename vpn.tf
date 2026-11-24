# VPN AWS <-> GCP: 2 tuneles IPsec (IKEv2) con BGP. Demo sin alta disponibilidad.
#
# Una sola conexion VPN de AWS trae 2 tuneles apuntando a UNA customer gateway,
# que aqui es la interfaz 0 del HA VPN gateway de GCP. Por eso ambos tuneles de
# GCP salen de la interfaz 0 (la interfaz 1 queda sin usar).
# En GCP el peer es un external VPN gateway TWO_IPS_REDUNDANCY (2 IPs de AWS):
#   t1: GCP interfaz 0 -> AWS tunel 1  (interfaz del peer externo 0)
#   t2: GCP interfaz 0 -> AWS tunel 2  (interfaz del peer externo 1)
# Sin los 4 tuneles (2 conexiones, una por interfaz) no aplica el SLA 99.99%.
resource "google_compute_ha_vpn_gateway" "this" {
  name       = "${var.name_prefix}-ha-vpn-gw"
  region     = var.gcp_region
  network    = google_compute_network.main.id
  stack_type = "IPV4_ONLY"
}

resource "google_compute_router" "this" {
  name    = "${var.name_prefix}-router"
  region  = var.gcp_region
  network = google_compute_network.main.id

  bgp {
    asn            = var.gcp_bgp_asn
    advertise_mode = "DEFAULT"
  }
}

# Una sola customer gateway: la interfaz 0 del HA VPN gateway de GCP.
resource "aws_customer_gateway" "gcp" {
  bgp_asn    = var.gcp_bgp_asn
  ip_address = google_compute_ha_vpn_gateway.this.vpn_interfaces[0].ip_address
  type       = "ipsec.1"

  tags = {
    Name = "${var.name_prefix}-cgw-gcp-if0"
  }
}

# Prefijo fijo 'p': AWS exige que la PSK no empiece con 0.
resource "random_password" "psk" {
  for_each = toset(["t1", "t2"])

  length  = 32
  special = false
}

locals {
  psk = { for k, v in random_password.psk : k => "p${v.result}" }
}

resource "aws_vpn_connection" "this" {
  customer_gateway_id = aws_customer_gateway.gcp.id
  vpn_gateway_id      = local.vpn_target.vpn_gateway_id
  transit_gateway_id  = local.vpn_target.transit_gateway_id
  type                = "ipsec.1"
  static_routes_only  = false

  tunnel1_inside_cidr   = "169.254.10.0/30"
  tunnel2_inside_cidr   = "169.254.10.4/30"
  tunnel1_preshared_key = local.psk["t1"]
  tunnel2_preshared_key = local.psk["t2"]

  tunnel1_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_dh_group_numbers      = [14]
  tunnel1_startup_action               = "start"

  tunnel2_ike_versions                 = ["ikev2"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_dh_group_numbers      = [14]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_dh_group_numbers      = [14]
  tunnel2_startup_action               = "start"

  tags = {
    Name = "${var.name_prefix}-vpn"
  }

  depends_on = [aws_vpn_gateway_attachment.this, aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "google_compute_external_vpn_gateway" "aws" {
  name            = "${var.name_prefix}-aws-peer-gw"
  redundancy_type = "TWO_IPS_REDUNDANCY"
  description     = "Peer AWS: 2 IPs publicas (1 conexion VPN x 2 tuneles)"

  interface {
    id         = 0
    ip_address = aws_vpn_connection.this.tunnel1_address
  }

  interface {
    id         = 1
    ip_address = aws_vpn_connection.this.tunnel2_address
  }
}

locals {
  # Atributos de cada tunel; ambos salen de la interfaz 0 de GCP.
  tunnels = {
    t1 = {
      gcp_if      = 0
      peer_if     = 0
      cgw_inside  = aws_vpn_connection.this.tunnel1_cgw_inside_address
      vgw_inside  = aws_vpn_connection.this.tunnel1_vgw_inside_address
      description = "AWS tunel 1"
    }
    t2 = {
      gcp_if      = 0
      peer_if     = 1
      cgw_inside  = aws_vpn_connection.this.tunnel2_cgw_inside_address
      vgw_inside  = aws_vpn_connection.this.tunnel2_vgw_inside_address
      description = "AWS tunel 2"
    }
  }
}

resource "google_compute_vpn_tunnel" "this" {
  for_each = local.tunnels

  name                            = "${var.name_prefix}-tunnel-${each.key}"
  region                          = var.gcp_region
  description                     = each.value.description
  vpn_gateway                     = google_compute_ha_vpn_gateway.this.id
  vpn_gateway_interface           = each.value.gcp_if
  peer_external_gateway           = google_compute_external_vpn_gateway.aws.id
  peer_external_gateway_interface = each.value.peer_if
  shared_secret                   = local.psk[each.key]
  router                          = google_compute_router.this.id
  ike_version                     = 2
}

resource "google_compute_router_interface" "this" {
  for_each = local.tunnels

  name       = "${var.name_prefix}-if-${each.key}"
  region     = var.gcp_region
  router     = google_compute_router.this.name
  ip_range   = "${each.value.cgw_inside}/30"
  vpn_tunnel = google_compute_vpn_tunnel.this[each.key].name
}

resource "google_compute_router_peer" "this" {
  for_each = local.tunnels

  name            = "${var.name_prefix}-peer-${each.key}"
  region          = var.gcp_region
  router          = google_compute_router.this.name
  interface       = google_compute_router_interface.this[each.key].name
  peer_ip_address = each.value.vgw_inside
  peer_asn        = var.aws_bgp_asn
}
