# Voting App on Kubernetes

Learning project: take `dockersamples/example-voting-app`, understand it deeply, automate it,
and deploy it to Kubernetes with realistic scaling, GitOps, and full observability
(traces/logs/metrics) — all provisioned via Terraform.

Full plan and progress notes live in [`docs/project-plan.md`](docs/project-plan.md) and
[`docs/my-notes.md`](docs/my-notes.md) — those files are the source of truth; update them as
decisions change.

## Repo layout

- `app/` — the voting app services (vote, worker, result, redis, db)
- `infra/terraform/cluster/` — VPC, EKS cluster, node group, IAM roles, EBS CSI driver/IRSA — the
  long-lived infrastructure layer
- `infra/terraform/app/` — first-pass Terraform-managed app deployment (frozen — no longer
  applied; superseded by Argo CD below, kept for reference)
- `infra/terraform/argocd/` — Argo CD install + the `Application` resource that points at `k8s/argocd/`
- `k8s/base/` — plain manifests for the local `kind` cluster (Ingress-based access)
- `k8s/argocd/` — manifests Argo CD syncs from on AWS (LoadBalancer-based access) — this is the
  actual current source of truth for what runs in the cluster
- `.github/workflows/` — CI: selective build + push images on push, retag-not-rebuild on release
- `scripts/` — automation scripts (`build-and-push.sh`, later the traffic generator)
- `docs/` — plan, notes, diagrams

## Status

Phase 6 (Argo CD/GitOps) complete. Full stack — cluster, Argo CD, all 5 services — proven to go
from nothing to fully working on real AWS in well under 15 minutes, and cleanly destroyable back
to nothing with no orphaned cloud resources. Environment is currently destroyed (cost-saving
between sessions); rebuild via `infra/terraform/cluster` → `infra/terraform/argocd` → confirm
Argo CD sync.

Next up: observability (traces/logs/metrics) and real scaling (HPA, DB read replicas), per the plan.

## Local dev

```bash
cd app
docker compose up --build
```

Vote UI: http://localhost:8080 · Results UI: http://localhost:8081

## Rebuilding the AWS environment from scratch

```bash
cd infra/terraform/cluster && terraform apply
cd ../argocd && terraform apply -target=helm_release.argocd && terraform apply
kubectl get application -n argocd   # wait for Synced/Healthy
```

## Tearing it down

Argo CD's `selfHeal` will fight a plain `kubectl delete` — always tear down via the cascade
finalizer (already baked into `argocd-app.tf`), and always in this order:

```bash
kubectl delete application voting-app -n argocd   # cascade-deletes the app, cleans up real AWS ELBs/EBS
# verify: kubectl get svc/pvc/pods (should be empty) AND check the AWS console directly
cd infra/terraform/argocd && terraform destroy
cd ../cluster && terraform destroy
```