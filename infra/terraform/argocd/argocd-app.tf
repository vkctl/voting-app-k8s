resource "kubernetes_manifest" "vote_app" {
    manifest = {
        apiVersion = "argoproj.io/v1alpha1"
        kind = "Application"
        metadata = {
            name = "voting-app"
            namespace = "argocd"
        }
        spec = {
            project = "default"

            source = {
                repoURL = "https://github.com/vkctl/voting-app-k8s.git"
                targetRevision = "main"
                path = "k8s/argocd"
            }

            destination = {
                server = "https://kubernetes.default.svc"
                namespace = "default"
            }

            syncPolicy = {
                automated = {
                    prune = true
                    selfHeal = true
                }
            }
        }
    }

    depends_on = [helm_release.argocd]
}