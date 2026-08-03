variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "demo-cluster"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster. Check current supported versions at https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html before applying — AWS retires old versions periodically. Also affects which Canonical Ubuntu EKS AMI gets looked up, so it must be a version Canonical has published a matching image for (see ubuntu_release)."
  type        = string
  default     = "1.36"
}

variable "ubuntu_release" {
  description = "Ubuntu LTS release used for EKS worker node AMIs, as published by Canonical (e.g. 24.04 = noble, supports EKS 1.31+). See https://documentation.ubuntu.com/aws/aws-how-to/instances/find-ubuntu-images/ for which release pairs with which Kubernetes version."
  type        = string
  default     = "24.04"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

variable "node_instance_types" {
  description = "Instance types for the managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Project   = "eks-gitops-demo"
    ManagedBy = "terraform"
  }
}
