# create route server
resource "aws_vpc_route_server" "vpc1-rs1" {
  amazon_side_asn           = var.rs_amazon_side_asn
  persist_routes            = "disable"
  #  persist_routes_duration   = 1
  sns_notifications_enabled = false

  tags = merge(
    local.tags,
    {
    Name = "${module.rosa-vpc.name}-rs1"
    }
  )
}


# associate route server with VPC
resource "aws_vpc_route_server_vpc_association" "vpc1-rs1-assoc" {
  route_server_id = aws_vpc_route_server.vpc1-rs1.route_server_id
  vpc_id = module.rosa-vpc.vpc_id
  depends_on = [module.rosa-vpc]
}


# enable propagation for private subnets
resource "aws_vpc_route_server_propagation" "vpc1-rs1-propag" {
  count = length(module.rosa-vpc.private_route_table_ids)
  route_server_id = aws_vpc_route_server.vpc1-rs1.route_server_id
  route_table_id = module.rosa-vpc.private_route_table_ids[count.index]
  depends_on = [aws_vpc_route_server_vpc_association.vpc1-rs1-assoc , module.rosa-vpc]
}
# enable propagation for public subnets
resource "aws_vpc_route_server_propagation" "vpc1-rs1-propag_pub" {
  count = length(module.rosa-vpc.public_route_table_ids)
  route_server_id = aws_vpc_route_server.vpc1-rs1.route_server_id
  route_table_id = module.rosa-vpc.public_route_table_ids[count.index]
  depends_on = [aws_vpc_route_server_vpc_association.vpc1-rs1-assoc , module.rosa-vpc]
}

# create route server endpoints in private subnets
# !! WIP - static 3 sets of 2 endpoints, expecting 3 private subnets. To be changed into for_each loop

# subnet1
resource "aws_vpc_route_server_endpoint" "vpc1-rs1-subnet1-ep1" {
  route_server_id = aws_vpc_route_server.vpc1-rs1.route_server_id
  subnet_id = module.rosa-vpc.private_subnets[0]
  tags = merge(
    local.tags,
    {
    Name = "${module.rosa-vpc.name}-rs1-private_subnet1-ep1"
    }
  )
  depends_on = [aws_vpc_route_server_vpc_association.vpc1-rs1-assoc]
}
resource "aws_vpc_route_server_endpoint" "vpc1-rs1-subnet1-ep2" {
  route_server_id = aws_vpc_route_server.vpc1-rs1.route_server_id
  subnet_id = module.rosa-vpc.private_subnets[0]
  tags = merge(
    local.tags,
    {
    Name = "${module.rosa-vpc.name}-rs1-private_subnet1-ep2"
    }
  )
  depends_on = [aws_vpc_route_server_vpc_association.vpc1-rs1-assoc]
}

# subnet2
resource "aws_vpc_route_server_endpoint" "vpc1-rs1-subnet2-ep1" {
  route_server_id = aws_vpc_route_server.vpc1-rs1.route_server_id
  subnet_id = module.rosa-vpc.private_subnets[1]
  tags = merge(
    local.tags,
    {
    Name = "${module.rosa-vpc.name}-rs1-private_subnet2-ep1"
    }
  )
  depends_on = [aws_vpc_route_server_vpc_association.vpc1-rs1-assoc]
}
resource "aws_vpc_route_server_endpoint" "vpc1-rs1-subnet2-ep2" {
  route_server_id = aws_vpc_route_server.vpc1-rs1.route_server_id
  subnet_id = module.rosa-vpc.private_subnets[1]
  tags = merge(
    local.tags,
    {
    Name = "${module.rosa-vpc.name}-rs1-private_subnet2-ep2"
    }
  )
  depends_on = [aws_vpc_route_server_vpc_association.vpc1-rs1-assoc]
}

# subnet3
resource "aws_vpc_route_server_endpoint" "vpc1-rs1-subnet3-ep1" {
  route_server_id = aws_vpc_route_server.vpc1-rs1.route_server_id
  subnet_id = module.rosa-vpc.private_subnets[2]
  tags = merge(
    local.tags,
    {
    Name = "${module.rosa-vpc.name}-rs1-private_subnet3-ep1"
    }
  )
  depends_on = [aws_vpc_route_server_vpc_association.vpc1-rs1-assoc]
}
resource "aws_vpc_route_server_endpoint" "vpc1-rs1-subnet3-ep2" {
  route_server_id = aws_vpc_route_server.vpc1-rs1.route_server_id
  subnet_id = module.rosa-vpc.private_subnets[2]
  tags = merge(
    local.tags,
    {
    Name = "${module.rosa-vpc.name}-rs1-private_subnet3-ep2"
    }
  )
  depends_on = [aws_vpc_route_server_vpc_association.vpc1-rs1-assoc]
}

# OUTPUTS

# endpoint IPs
output "vpc1-rs1-subnet1-ep1_ip" {
  value = aws_vpc_route_server_endpoint.vpc1-rs1-subnet1-ep1.eni_address
}
output "vpc1-rs1-subnet1-ep2_ip" {
  value = aws_vpc_route_server_endpoint.vpc1-rs1-subnet1-ep2.eni_address
}
output "vpc1-rs1-subnet2-ep1_ip" {
  value = aws_vpc_route_server_endpoint.vpc1-rs1-subnet2-ep1.eni_address
}
output "vpc1-rs1-subnet2-ep2_ip" {
  value = aws_vpc_route_server_endpoint.vpc1-rs1-subnet2-ep2.eni_address
}
output "vpc1-rs1-subnet3-ep1_ip" {
  value = aws_vpc_route_server_endpoint.vpc1-rs1-subnet3-ep1.eni_address
}
output "vpc1-rs1-subnet3-ep2_ip" {
  value = aws_vpc_route_server_endpoint.vpc1-rs1-subnet3-ep2.eni_address
}

output "vpc1-rs1-asn" {
  value = aws_vpc_route_server.vpc1-rs1.amazon_side_asn
}

output "rosa_bgp_asn" {
  value = var.rosa_bgp_asn
}
