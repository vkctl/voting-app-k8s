resource "kubernetes_deployment_v1" "result" {
  metadata {
    name = "result"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "result"
      }
    }

    template {
      metadata {
        labels = {
          app = "result"
        }
      }

      spec {
        container {
          name  = "result"
          image = "ghcr.io/${var.image_owner}/result:${var.result_image_tag}"

          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "result" {
  metadata {
    name = "result"
  }

  spec {
    type = "LoadBalancer"
    selector = {
      app = "result"
    }

    port {
      port = 80
      target_port = 80
    }
  }
}
