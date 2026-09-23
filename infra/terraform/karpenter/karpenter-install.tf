locals {
  karpenter_version = "1.14.1"
}


resource "helm_release" "karpenter_crd" {
  name = "karpenter-crd"
  repository = "oci://public.ecr.aws/karpenter"
  chart = "karpenter-crd"
  version = local.karpenter_version
  namespace = "kube-system"
}

resource "helm_release" "karpenter" {
  name = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart = "karpenter"
  version = local.karpenter_version
  namespace = "kube-system"


  set {
    name = "settings.clusterName"
    value = "voting-app"
  }

  set {
    name = "settings.interruptionQueue"
    value = data.aws_sqs_queue.karpenter.name
  }

  depends_on = [helm_release.karpenter_crd]
}
