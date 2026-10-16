output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs, in AZ order."
  value       = [for az in var.azs : aws_subnet.public[az].id]
}

output "app_subnet_ids" {
  description = "Private application subnet IDs, in AZ order."
  value       = [for az in var.azs : aws_subnet.app[az].id]
}

output "db_subnet_ids" {
  description = "Isolated database subnet IDs, in AZ order."
  value       = [for az in var.azs : aws_subnet.db[az].id]
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs keyed by AZ."
  value       = { for az, n in aws_nat_gateway.main : az => n.id }
}

output "public_subnets_auto_assign_public_ip" {
  description = "map_public_ip_on_launch per public subnet (must all be false)."
  value       = [for s in aws_subnet.public : s.map_public_ip_on_launch]
}
