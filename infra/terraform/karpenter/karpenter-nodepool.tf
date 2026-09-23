resource "kubernetes_manifest" "ec2nodeclass_default" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      amiFamily = "AL2023"
      amiSelectorTerms = [
        { alias = "al2023@latest" }
      ]
      role = "voting-app-karpenter-node"

      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = "voting-app" } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = "voting-app" } }
      ]
    }
  }

  depends_on = [helm_release.karpenter_crd]
}


resource "kubernetes_manifest" "nodepool_default" {
  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind = "NodePool"
    metadata = {
      name = "default"
    }
    spec = {
      template = {
        spec = {
          requirements = [
            {
              key = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = ["t3.micro", "t3.small"]
            },
            {
              key = "karpenter.sh/capacity-type"
              operator = "In"
              values = ["on-demand"]
            }
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
        }
      }
      limits = {
        cpu = "8"
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }
    }
  }

  depends_on = [helm_release.karpenter_crd]
}
