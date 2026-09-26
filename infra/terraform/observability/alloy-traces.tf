# A SEPARATE release from the log-shipping alloy.tf — same chart, different
# job. This one needs to be a Deployment (one stable Service endpoint apps
# push traces to), not a DaemonSet (which makes sense for tailing each
# node's own log files, not for receiving pushed data).
resource "helm_release" "alloy_traces" {
  name = "alloy-traces"
  repository = "https://grafana.github.io/helm-charts"
  chart = "alloy"
  version = "1.11.1"
  namespace = "observability"
  create_namespace = true

  values = [
    yamlencode({
      controller = {
        type     = "deployment"
        replicas = 1
      }
      alloy = {
        extraPorts = [
          {
            name       = "otlp-grpc"
            port       = 4317
            targetPort = 4317
            protocol   = "TCP"
          },
          {
            name       = "otlp-http"
            port       = 4318
            targetPort = 4318
            protocol   = "TCP"
          }
        ]
        configMap = {
          create = true
          # Receives OTLP traces from apps, forwards to Tempo. Same
          # component-based Alloy syntax as the log-shipping config,
          # different components for a different job.
          content = <<-EOT
            otelcol.receiver.otlp "otlp_receiver" {
              grpc {
                endpoint = "0.0.0.0:4317"
              }
              http {
                endpoint = "0.0.0.0:4318"
              }
              output {
                traces = [otelcol.exporter.otlp.tempo.input]
              }
            }

            otelcol.exporter.otlp "tempo" {
              client {
                endpoint = "tempo.observability.svc.cluster.local:4317"
                tls {
                  insecure = true
                }
              }
            }
          EOT
        }
      }
    })
  ]
}
