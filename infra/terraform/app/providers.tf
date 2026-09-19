terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source = "hashicorp/helm"
      version = "~> 2.16"
    } 
  }
}

provider "aws" {
  region = "ap-south-2"   # must match whatever region cluster/ actually created the EKS cluster in
}

data "aws_eks_cluster" "main" {
  name = "voting-app"
}

data "aws_eks_cluster_auth" "main" {
  name = "voting-app"
}

provider "kubernetes" {
  host = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token = data.aws_eks_cluster_auth.main.token
}

resource "kubernetes_storage_class_v1" "ebs_gp3" {
  metadata {
    name = "ebs-gp3"
  }
  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy = "Delete"
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type = "gp3"
  }
}
