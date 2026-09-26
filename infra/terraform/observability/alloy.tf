resource "helm_release" "alloy" {
  name = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart = "alloy"
  version = "1.11.1"
  namespace = "observability"
  create_namespace = true

  values = [
    yamlencode({
      alloy = {
        mounts = {
          varlog = true   # mounts the node's /var/log so Alloy can actually read container logs
        }
        configMap = {
          content = <<-EOT
            logging {
              level  = "info"
              format = "logfmt"
            }

            discovery.kubernetes "pods" {
              role = "pod"
            }

            loki.source.kubernetes "pods" {
              targets = discovery.kubernetes.pods.targets
              forward_to = [loki.write.endpoint.receiver]
            }

            loki.write "endpoint" {
              endpoint {
                url = "http://loki-gateway.observability.svc.cluster.local:80/loki/api/v1/push"
                tenant_id = "local"
              }
            }
          EOT
        }
      }
    })
  ]
}
