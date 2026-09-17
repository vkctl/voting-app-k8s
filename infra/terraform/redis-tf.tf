resource "kubernetes_deployment_v1" "redis" {
    metadata {
        name = "redis"
    }

    spec {
        replicas = 1

        selector {
            match_labels = {
                app = "redis"
            }
        }

        template {
            metadata {
                labels = {
                    app = "redis"
                }
            }

            spec {
                container {
                    name = "redis"
                    image = "redis:alpine"

                    port{
                        container_port = 6379
                    }
                }
            }
        }
    }
}

resource "kubernetes_service_v1" "redis" {
    metadata {
        name = "redis"
    }

    spec {
        selector = {
            app = "redis"
        }

        port{
            port = 6379
            target_port = 6379
        }
    }
}