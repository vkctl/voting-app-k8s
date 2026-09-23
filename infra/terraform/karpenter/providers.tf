terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source = "hashicorp/helm"
      version = "~> 2.16"
    }
  }
}

provider "aws" {
  region = "ap-south-2"
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

provider "helm" {
  kubernetes {
    host = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token = data.aws_eks_cluster_auth.main.token
  }
}

data "aws_sqs_queue" "karpenter" {
  name = "Karpenter-voting-app"
}
