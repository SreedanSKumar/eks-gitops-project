terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Canonical publishes official EKS-optimized Ubuntu AMIs, refreshed
# continuously, and exposes the current AMI ID per (Ubuntu release,
# Kubernetes version) pair via SSM Parameter Store. Looking it up here
# instead of hardcoding an AMI ID keeps this always pointing at the
# current image rather than going stale.
data "aws_ssm_parameter" "ubuntu_eks_ami" {
  name = "/aws/service/canonical/ubuntu/eks/${var.ubuntu_release}/${var.kubernetes_version}/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = var.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_group_defaults = {
    # instance root volume; Ubuntu's default is smaller than AL2's
    disk_size = 30
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "CUSTOM"
      ami_id         = data.aws_ssm_parameter.ubuntu_eks_ami.value
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
      capacity_type  = "ON_DEMAND"

      # Custom AMIs don't get EKS's managed bootstrap user data
      # automatically merged in — this tells the module to inject the
      # standard nodeadm bootstrap invocation itself. Canonical's Ubuntu
      # EKS AMIs (24.04/noble, for k8s 1.31+) use the same nodeadm-based
      # bootstrap flow as AL2023, so this "just works" the same way.
      enable_bootstrap_user_data = true
    }
  }

  # Lets your local IAM user/role administer the cluster via kubectl
  enable_cluster_creator_admin_permissions = true

  tags = var.tags
}
