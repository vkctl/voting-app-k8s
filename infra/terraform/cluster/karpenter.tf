module "karpenter" {
    source = "terraform-aws-modules/eks/aws//modules/karpenter"
    version = "~> 21.0"

    cluster_name = module.eks.cluster_name

    node_iam_role_use_name_prefix = false
    node_iam_role_name = "${var.project_name}-karpenter-node"
    create_pod_identity_association = true

    tags = {
        "karpenter.sh/discovery" = var.cluster_name
    }

}