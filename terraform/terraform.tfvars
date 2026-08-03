aws_region         = "us-east-1"
cluster_name       = "demo-cluster"
kubernetes_version = "1.36"
ubuntu_release     = "24.04"

node_instance_types = ["t3.medium"]
node_min_size       = 2
node_max_size       = 4
node_desired_size   = 2
