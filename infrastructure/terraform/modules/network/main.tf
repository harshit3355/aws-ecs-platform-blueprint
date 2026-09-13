# Network layer: a three-tier VPC.
#
#   public   -> internet-facing ALB only
#   private  -> ECS Fargate tasks, egress via NAT
#   database -> RDS only, no route to the internet at all
#
# The database tier is a separate subnet group rather than reusing the private
# subnets so that "the database cannot reach the internet" is a property of the
# route table, not of a security group someone can widen later.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /16 VPC carved into /20s: far more addresses per subnet than this workload
  # needs, but it leaves room to add tiers later without renumbering.
  public_subnets   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 4)]
  database_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.2"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets   = local.public_subnets
  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets

  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  # Explicitly no internet path for the database tier.
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway = true

  # The single biggest fixed cost lever in this stack. One NAT gateway is about
  # 32 USD/month plus data processing; one per AZ multiplies that by the AZ
  # count. Staging takes the shared gateway and accepts that an AZ failure costs
  # it egress; production pays for the redundancy.
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  # Flow logs are the access log of the network tier, and the only way to answer
  # "did anything actually reach the database subnet".
  #
  # REJECT only: ACCEPT traffic for a healthy service is high volume, expensive
  # to store, and already described by the ALB access logs. Rejected traffic is
  # the part that signals a misconfiguration or a probe.
  enable_flow_log                                 = var.enable_flow_logs
  create_flow_log_cloudwatch_log_group            = var.enable_flow_logs
  create_flow_log_cloudwatch_iam_role             = var.enable_flow_logs
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days
  flow_log_traffic_type                           = "REJECT"

  public_subnet_tags  = { Tier = "public" }
  private_subnet_tags = { Tier = "private" }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# VPC endpoints
# ---------------------------------------------------------------------------
# Interface endpoints keep ECR pulls, log shipping and secret reads off the NAT
# gateway. They are NOT unconditionally cheaper: each costs roughly 7.50 USD per
# month per AZ, so four endpoints across two AZs is about 60 USD/month. That
# only pays for itself above roughly 1.3 TB/month of NAT egress. Staging leaves
# them off; production turns them on and gains the private path as well as the
# saving. See README, "Cost optimization".

locals {
  interface_endpoints = var.enable_vpc_endpoints ? toset([
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager",
  ]) : toset([])
}

resource "aws_security_group" "endpoints" {
  count = var.enable_vpc_endpoints ? 1 : 0

  name_prefix = "${var.name}-vpce-"
  description = "Allow HTTPS from inside the VPC to interface VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count = var.enable_vpc_endpoints ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from within the VPC"
  cidr_ipv4         = module.vpc.vpc_cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name}-${each.value}" })
}

# The S3 gateway endpoint is free and always worth having: ECR stores image
# layers in S3, so without it every image pull is billed as NAT traffic.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(module.vpc.private_route_table_ids, module.vpc.database_route_table_ids)

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}
