resource "helm_release" "loki" {
  name = "loki"
  repository = "https://grafana-community.github.io/helm-charts"
  chart = "loki"
  version = "18.13.5"
  namespace = "observability"
  create_namespace = true

  values = [
    yamlencode({
      deploymentMode = "SingleBinary"
      loki = {
        commonConfig = {
          replication_factor = 1
        }
        storage = {
          type = "filesystem"
        }
        schemaConfig = {
          configs = [
            {
              from = "2024-01-01"
              store = "tsdb"
              object_store = "filesystem"
              schema = "v13"
              index = {
                prefix = "index_"
                period = "24h"
              }
            }
          ]
        }
        limits_config = {
            volume_enabled = true # needed for Grafana's Logs Drilldown volume histogram
        }
      }
      singleBinary = {
        replicas = 1
        persistence = {
          enabled = true
          storageClass = "ebs-gp3"
          size = "5Gi"
        }
      }
      # Disabling extras not needed for a learning setup — fewer Pods,
      # simpler to reason about, closer to the actual minimum viable stack.
      read = {
        replicas = 0
      }
      write = {
        replicas = 0
      }
      backend = {
        replicas = 0
      }
      chunksCache = {
        enabled = false
      }
      resultsCache = {
        enabled = false
      }
      lokiCanary = {
        enabled = false
      }
      test = {
        enabled = false
      }
      monitoring = {
        selfMonitoring = { enabled = false }
        lokiCanary     = { enabled = false }
      }
    })
  ]
}
