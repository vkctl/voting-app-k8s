resource "helm_release" "tempo" {
  name = "tempo"
  repository = "https://grafana-community.github.io/helm-charts"
  chart = "tempo"
  version = "3.0.0"
  namespace = "observability"
  create_namespace = true

  values = [
    yamlencode({
      tempo = {
        storage = {
          trace = {
            backend = "local"
            local = {
              path = "/var/tempo/traces"
            }
          }
        }
        receivers = {
          otlp = {
            protocols = {
              grpc = {}
              http = {}
            }
          }
        }
      }
      persistence = {
        enabled = true
        storageClassName = "ebs-gp3"
        size = "5Gi"
      }
    })
  ]
}
