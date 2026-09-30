# KEDA — event-driven autoscaling, here specifically for scaling worker
# based on the real Redis queue depth rather than CPU (which HPA already
# handles for vote/result). Deliberately living beside Karpenter/
# metrics-server/the StorageClass: same "cluster-wide platform prerequisite"
# category as those, not app-specific.
resource "helm_release" "keda" {
  name = "keda"
  repository = "https://kedacore.github.io/charts"
  chart = "keda"
  version = "2.21.0"
  namespace = "keda"
  create_namespace = true
}
