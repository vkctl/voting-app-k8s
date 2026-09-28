# Voting App on Kubernetes

Learning project: take `dockersamples/example-voting-app`, understand it deeply, automate it, and
run it on Kubernetes (EKS) with autoscaling, GitOps, and full observability (metrics, logs,
traces) — all provisioned with Terraform, rebuildable from nothing and destroyable back to nothing.

Full plan and progress notes live in [`docs/project-plan.md`](docs/project-plan.md) and
[`docs/my-notes.md`](docs/my-notes.md) — those files are the source of truth; update them as
decisions change.

Request flow: `vote → redis → worker → db → result`

## Repo layout

- `app/` — the voting app services (vote, worker, result, redis, db). `vote`, `worker` and
  `result` are instrumented with Prometheus metrics and OpenTelemetry tracing.
- `infra/terraform/cluster/` — VPC, EKS cluster, managed node group, IAM, EBS CSI driver and the
  Karpenter IAM/SQS resources, built on the community `terraform-aws-modules`. AWS resources only.
- `infra/terraform/karpenter/` — cluster-wide platform prerequisites: Karpenter (controller,
  `NodePool`, `EC2NodeClass`), `metrics-server`, and the `ebs-gp3` **StorageClass**. The
  StorageClass lives here deliberately — see [Build order](#build-order-matters).
- `infra/terraform/observability/` — `kube-prometheus-stack` (Prometheus, Grafana, Alertmanager),
  Loki, Tempo, and two Alloy instances (a DaemonSet shipping logs, a Deployment collecting traces).
- `infra/terraform/argocd/` — Argo CD install + the `Application` that watches `k8s/argocd/`.
- `infra/terraform/app/` — first-pass Terraform-managed app deployment (frozen — no longer
  applied; superseded by Argo CD, kept for reference).
- `k8s/base/` — plain manifests for the local `kind` cluster (Ingress-based access).
- `k8s/argocd/` — manifests Argo CD syncs on AWS (probes, HPAs, `ServiceMonitor`/`PodMonitor`s,
  LoadBalancer Services) — the current source of truth for what runs in the cluster.
- `.github/workflows/` — CI: selective build + push on push, retag-not-rebuild on release.
- `scripts/` — `build-and-push.sh` and `traffic-generator.py` (ramping load test).
- `docs/` — plan, notes, diagrams.

## Status

Complete and proven on real AWS:

- CI/CD with GitHub Actions (selective builds, release by retagging — no rebuilds)
- Terraform-provisioned EKS, deployable from nothing in roughly 10 minutes for the cluster plus a
  few more per layer, and destroyable back to nothing
- GitOps with Argo CD (self-healing, cascade teardown)
- Autoscaling at both layers under real load: HPA (Pods) and Karpenter (nodes)
- Metrics: Prometheus scraping all three apps plus Redis/Postgres via sidecar exporters
- Logs: Loki + Alloy, no app changes required

In progress — **traces**: Tempo and the Alloy trace collector are deployed, and `vote`, `worker`
and `result` are instrumented with OpenTelemetry (including manual trace-context propagation
across the Redis queue, which auto-instrumentation can't bridge). End-to-end verification in
Grafana is still pending.

Next: use the observability stack to diagnose the `worker` bottleneck (`Thread.Sleep(100)` caps it
at ~10 votes/sec), then rework it toward an async design.

The AWS environment is destroyed between sessions to keep costs down.

## Local dev

```bash
cd app
docker compose up --build
```

Vote UI: http://localhost:8080 · Results UI: http://localhost:8081

Metrics endpoints: `:8080/metrics` (vote), `:8081/metrics` (result), `:9090/metrics` (worker).

Locally you'll see OTLP export errors in the `vote`/`worker`/`result` logs — expected and harmless.
The trace collector address is a cluster-internal DNS name that only resolves inside EKS.

## Build order matters

The layers have real dependencies on each other — a from-scratch rebuild in the wrong order fails:

| Order | Directory | Why it goes here |
|---|---|---|
| 1 | `cluster/` | everything needs a cluster |
| 2 | `karpenter/` | node autoscaling, `metrics-server`, and the StorageClass everything with a PVC needs |
| 3 | `observability/` | installs the `ServiceMonitor` CRDs; Loki/Tempo need the StorageClass from step 2 |
| 4 | `argocd/` | its manifests need the CRDs from step 3 and the StorageClass from step 2 |

The StorageClass used to live in `k8s/argocd/`, which created a circular dependency (Loki/Tempo
needed it, but it only existed once Argo CD had synced — while Argo CD's own manifests needed CRDs
from `observability/`). It now lives in Terraform in `karpenter/`, ahead of both.

## Rebuilding the AWS environment from scratch

```bash
cd infra/terraform/cluster && terraform apply
aws eks update-kubeconfig --name voting-app --region ap-south-2

cd ../karpenter && terraform apply -target=helm_release.karpenter_crd && terraform apply
cd ../observability && terraform apply
cd ../argocd && terraform apply -target=helm_release.argocd && terraform apply

kubectl get application -n argocd   # wait for Synced/Healthy
```

The `-target` applies install CRDs before the resources that depend on them (Terraform can't
validate a custom resource whose CRD doesn't exist yet). App images come from CI (`ghcr.io`), so
they must already be built and pushed.

## Accessing the UIs

Grafana, Prometheus and Argo CD have no public endpoint — use port-forwards:

```bash
# Grafana → http://localhost:3000 (admin password is a placeholder set in observability/kube-prometheus-stack.tf)
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80

# Prometheus → http://localhost:9090/targets
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090

# Argo CD → https://localhost:8080 (user: admin)
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

`vote` and `result` each have their own LoadBalancer — `kubectl get svc vote result` shows the
hostnames. To generate load:

```bash
pip install requests
python scripts/traffic-generator.py --url http://<vote-elb-hostname>
```

## Tearing it down

Reverse of the build order. Argo CD's `selfHeal` will fight a plain `kubectl delete`, and several
resources have real AWS objects behind them (ELBs, EBS volumes, EC2 instances) that only get
cleaned up if they're deleted **while the cluster is still alive**.

```bash
kubectl delete application voting-app -n argocd   # cascade-deletes the app: cleans up its ELBs and db's EBS volume
kubectl get svc,pvc,pods                          # should be empty (apart from the built-in kubernetes Service)

cd infra/terraform/argocd && terraform destroy
cd ../observability && terraform destroy
kubectl get pvc -n observability                  # Loki/Tempo PVCs can outlive a helm uninstall — delete any leftovers
cd ../karpenter && terraform destroy              # while the cluster is alive, so Karpenter can terminate the nodes it launched
cd ../cluster && terraform destroy
```

Then verify directly in the AWS Console — don't trust Terraform's word alone:

- **EC2 → Load Balancers** — none left
- **EC2 → Volumes** — nothing `available`/unattached (Loki's and Tempo's PVC volumes are the easy ones to miss)
- **EC2 → Instances** — no Karpenter-launched instances still running (they're not tracked in Terraform state)