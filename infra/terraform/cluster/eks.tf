resource "aws_eks_cluster" "main" {
    name = var.cluster_name
    role_arn = aws_iam_role.eks_cluster.arn

    vpc_config {
        subnet_ids = aws_subnet.public[*].id
        endpoint_public_access = true
        endpoint_private_access = false
    }

    depends_on = [
        aws_iam_role_policy_attachment.eks_cluster_policy
    ]
}