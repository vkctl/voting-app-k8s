resource "aws_eks_node_group" "main" {
    cluster_name = aws_eks_cluster.main.name
    node_group_name = "${var.project_name}-nodes"
    node_role_arn = aws_iam_role.eks_nodes.arn
    subnet_ids = aws_subnet.public[*].id

    instance_types = ["t3.small"]
    capacity_type = "ON_DEMAND"

    scaling_config {
        min_size = 1
        max_size = 3
        desired_size = 2
    }

    depends_on = [
        aws_iam_role_policy_attachment.eks_worker_node_policy,
        aws_iam_role_policy_attachment.eks_cni_policy,
        aws_iam_role_policy_attachment.eks_ecr_readonly,
    ]
}