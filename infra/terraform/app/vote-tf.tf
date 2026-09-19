resource "kubernetes_deployment_v1" "vote" {
  metadata {
    name = "vote"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "vote"
      }
    }

    template {
      metadata {
        labels = {
          app = "vote"
        }
      }

      spec {
        container {
          name  = "vote"
          image = "ghcr.io/${var.image_owner}/vote:${var.vote_image_tag}"

          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "vote" {
  metadata {
    name = "vote"
  }

  spec {
    type = "LoadBalancer"
    selector = {
      app = "vote"
    }

    port {
      port = 80
      target_port = 80
    }
  }
}
