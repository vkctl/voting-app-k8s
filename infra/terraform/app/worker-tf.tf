resource "kubernetes_deployment_v1" "worker" {
    metadata {
        name = "worker"
    }
    spec {
        replicas = 1

        selector {
            match_labels = {
                app = "worker"
            }
        }

        template {
            metadata {
                labels ={
                    app = "worker"
                }
            }
            spec {
                container{
                    name = "worker"
                    image = "ghcr.io/${var.image_owner}/worker:${var.worker_image_tag}"
                }
            }
        }
    }
}