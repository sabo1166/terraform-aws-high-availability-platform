locals {
  # /24 carve-up: public 0..2, private app 10..12, isolated db 20..22
  public_subnets = { for i, az in var.azs : az => cidrsubnet(var.vpc_cidr, 8, i) }
  app_subnets    = { for i, az in var.azs : az => cidrsubnet(var.vpc_cidr, 8, 10 + i) }
  db_subnets     = { for i, az in var.azs : az => cidrsubnet(var.vpc_cidr, 8, 20 + i) }

  nat_azs = var.nat_gateway_mode == "per_az" ? var.azs : [var.azs[0]]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

# Empty the default SG so nothing relies on it.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name}-default-DO-NOT-USE" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name}-igw" }
}

############################
# Subnets
############################
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false # only ALB/NAT ENIs live here; no auto public IPs

  tags = { Name = "${var.name}-public-${each.key}", Tier = "public" }
}

resource "aws_subnet" "app" {
  for_each = local.app_subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = { Name = "${var.name}-app-${each.key}", Tier = "private-app" }
}

resource "aws_subnet" "db" {
  for_each = local.db_subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = { Name = "${var.name}-db-${each.key}", Tier = "isolated-db" }
}

############################
# NAT
############################
resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"
  tags   = { Name = "${var.name}-nat-eip-${each.key}" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = { Name = "${var.name}-nat-${each.key}" }

  depends_on = [aws_internet_gateway.main]
}

############################
# Route tables
############################
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name}-rt-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ; each points at its own NAT (per_az) or the shared NAT (single).
resource "aws_route_table" "app" {
  for_each = aws_subnet.app

  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name}-rt-app-${each.key}" }
}

resource "aws_route" "app_nat" {
  for_each = aws_route_table.app

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[var.nat_gateway_mode == "per_az" ? each.key : var.azs[0]].id
}

resource "aws_route_table_association" "app" {
  for_each = aws_subnet.app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.app[each.key].id
}

# Isolated DB tier: a route table with ONLY the implicit local route. No default route.
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name}-rt-db-isolated" }
}

resource "aws_route_table_association" "db" {
  for_each = aws_subnet.db

  subnet_id      = each.value.id
  route_table_id = aws_route_table.db.id
}

# Gateway endpoint (no hourly cost): S3-bound traffic bypasses the NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.app : rt.id]

  tags = { Name = "${var.name}-vpce-s3" }
}

############################
# Flow logs
############################
resource "aws_cloudwatch_log_group" "flow" {
  #checkov:skip=CKV_AWS_158:KMS-encrypting log groups needs a CMK; cost/complexity trade-off for a lab
  #checkov:skip=CKV_AWS_338:Retention is a variable (log_retention_days); 1 year is costly for a lab
  count = var.enable_flow_logs ? 1 : 0

  name              = "/${var.name}/vpc-flow-logs"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.name}-flowlogs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name = "write-flow-logs"
  role = aws_iam_role.flow[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow[0].arn}:*"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow[0].arn
  iam_role_arn             = aws_iam_role.flow[0].arn
  max_aggregation_interval = 600
}
