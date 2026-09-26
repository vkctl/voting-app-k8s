resource "helm_release" "kube_prometheus_stack" {
  name = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart = "kube-prometheus-stack"
  version = "91.5.1"
  namespace = "observability"
  create_namespace = true
  timeout = 600

  values = [
    yamlencode({
      grafana = {
        adminPassword = "admin"
        additionalDataSources = [
          {
            name = "Loki"
            type = "loki"
            url = "http://loki-gateway.observability.svc.cluster.local"
            access = "proxy"
            isDefault = false
            jsonData = {
              httpHeaderName1 = "X-Scope-OrgID"
            }
            secureJsonData = {
              httpHeaderValue1 = "local"
            }
          }
        ]
      }
    })
  ]
}
