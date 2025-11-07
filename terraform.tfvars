# Variables for environment

aws_region = "eu-central-1"
owner = "CHANGE-ME" # used as tag Owner = var.owner for AWS resources
project = "ROSA-Virt BGP" # used as tag Project = var.project for AWS resources
project_id = "-bgp" # Optional: appended to AWS resource names after owner for easier identification, e.g. name = "${var.owner}${var.project_id}-vpc1-rosa". If kept empty, then it will be omitted 

rosa_cluster_name = "myrosa1"
rosa_openshift_version = "4.20.0"
rosa_compute_instance_type = "c5.metal"
rosa_bgp_asn = "65001" # OCP AS number - used for k8s-frr config

vpc1-rosa_cidr = "10.0.0.0/16"
vpc1-rosa_private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
vpc1-rosa_public_subnets = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
rs_amazon_side_asn = "65000" # AS number of route server

vpc2-ext_cidr = "192.168.0.0/16"
vpc2-ext_private_subnets = ["192.168.1.0/24", "192.168.2.0/24", "192.168.3.0/24"]
vpc2-ext_public_subnets = ["192.168.101.0/24", "192.168.102.0/24", "192.168.103.0/24"]
