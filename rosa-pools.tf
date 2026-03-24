module "router-pool1" {
  source = "terraform-redhat/rosa-hcp/rhcs//modules/machine-pool"
  version = ">= 1.6.2"

  cluster_id = module.hcp.cluster_id
  name = "bm1"
  openshift_version = module.hcp.cluster_current_version
  labels = {
    bgp_router = "true",
    bgp_router_subnet = "1",
    az = "1",
  }

  aws_node_pool = {
    instance_type = var.rosa_compute_instance_type
    tags = {
      bgp_router = "true",
      bgp_router_subnet = "1",
      az = "1",
      Owner = var.owner
    }
    additional_security_group_ids = tolist(
      [
        aws_security_group.rosa_rfc1918_sg.id,
        aws_security_group.rosa_allow_from_all_sg.id
      ]
    )
    ec2_metadata_http_tokens = "required"
  }

  subnet_id = module.rosa-vpc.private_subnets[0]
  autoscaling = {
    enabled = false
    min_replicas = null
    max_replicas = null
  }
  replicas = 1
}


module "router-pool2" {
  source = "terraform-redhat/rosa-hcp/rhcs//modules/machine-pool"
  version = ">= 1.6.2"

  cluster_id = module.hcp.cluster_id
  name = "bm2"
  openshift_version = module.hcp.cluster_current_version
  labels = {
    bgp_router = "true",
    bgp_router_subnet = "2",
    az = "2",
  }

  aws_node_pool = {
    instance_type = var.rosa_compute_instance_type
    tags = {
      bgp_router = "true",
      bgp_router_subnet = "2",
      az = "2",
      Owner = var.owner
    }
    additional_security_group_ids = tolist(
      [
        aws_security_group.rosa_rfc1918_sg.id,
        aws_security_group.rosa_allow_from_all_sg.id
      ]
    )
    ec2_metadata_http_tokens = "required"
  }

  subnet_id = module.rosa-vpc.private_subnets[1]
  autoscaling = {
    enabled = false
    min_replicas = null
    max_replicas = null
  }
  replicas = 1
}

module "router-pool3" {
  source = "terraform-redhat/rosa-hcp/rhcs//modules/machine-pool"
  version = ">= 1.6.2"

  cluster_id = module.hcp.cluster_id
  name = "bm3"
  openshift_version = module.hcp.cluster_current_version
  labels = {
    bgp_router = "true",
    bgp_router_subnet = "3",
    az = "3",
  }

  aws_node_pool = {
    instance_type = var.rosa_compute_instance_type
    tags = {
      bgp_router = "true",
      bgp_router_subnet = "3",
      az = "3",
      Owner = var.owner
    }
    additional_security_group_ids = tolist(
      [
        aws_security_group.rosa_rfc1918_sg.id,
        aws_security_group.rosa_allow_from_all_sg.id
      ]
    )
    ec2_metadata_http_tokens = "required"
  }

  subnet_id = module.rosa-vpc.private_subnets[2]
  autoscaling = {
    enabled = false
    min_replicas = null
    max_replicas = null
  }
  replicas = 1
}
