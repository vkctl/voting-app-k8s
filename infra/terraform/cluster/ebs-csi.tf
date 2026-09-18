data "tls_certificate" "eks_oidc" {
    url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
    url = aws_eks_cluster.main.identity[0].oidc[0].issuer
    client_id_list = ["sts.amazonaws.com"]
    thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "ebs_csi_driver" {
    name = "${var.project_name}-ebs-csi-driver-role"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect = "Allow"
            Principal = {
                Federated = aws_iam_openid_connect_provider.eks.arn
            }
            Action = "sts:AssumeRoleWithWebIdentity"
            Condition = {
                StringEquals = {
                    "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
                    "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
                }
            }
        }]
    })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
    role = aws_iam_role.ebs_csi_driver.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi_driver" {
    cluster_name = aws_eks_cluster.main.name
    addon_name = "aws-ebs-csi-driver"
    service_account_role_arn = aws_iam_role.ebs_csi_driver.arn

    depends_on = [aws_eks_node_group.main]
}