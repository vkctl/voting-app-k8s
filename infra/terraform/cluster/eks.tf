module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name = var.cluster_name
  kubernetes_version = "1.36"

  endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true
 

  vpc_id = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

# Currently t3.small has max cap of pods at 11 due to AWS_CNI
# Alternates option a: include Prefix delegation to vpc cni addon - assigns 110 ips to a node so it, to limit add bootstrap args to eks managed node eks_managed_node_groups
# option b: use cilium
# option c: increase desired nodes
  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      max_size       = 5
      desired_size   = 3
    }
  }

  addons = {
    vpc-cni = {
      most_recent = true
      before_compute = true
    }

    coredns = {
      most_recent = true
    }

    kube-proxy = {
      most_recent = true
    }

    eks-pod-identity-agent = {
      before_compute = true
      most_recent = true
    }

    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [
        {
        role_arn = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
        }
      ]
    }
  }

  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}


module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${var.project_name}-aws-ebs-csi"
  attach_aws_ebs_csi_policy = true
}
