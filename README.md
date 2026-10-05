# Voting App on Kubernetes

A personal project built on [`dockersamples/example-voting-app`](https://github.com/dockersamples/example-voting-app):
run it on AWS EKS, build full observability (metrics, logs, traces), and use that observability to
find and fix real performance problems under load. Everything is provisioned with Terraform and
delivered with Argo CD, and the whole environment can be rebuilt from nothing and destroyed back to nothing.

Request flow: `vote → redis → worker → db → result`

The complete investigation log, including dead ends and corrections, is in
[`docs/my-notes.md`](docs/my-notes.md); the original plan is in [`docs/project-plan.md`](docs/project-plan.md).

## What this project found

Metrics, logs and traces were built first. Load testing then drove three rounds of diagnosis and fixes:

| Round | Setup | Observed |
|---|---|---|
| Baseline | 1 `worker`, unconditional `Thread.Sleep(100)` every loop | ~10 votes/s ceiling. A 1,000-vote burst left a ~570-vote backlog; longest trace 1m 24s, almost all of it queue wait, while `db_write` took ~1.6 ms |
| Fix 1 | Sleep only when the queue is empty | Same burst: longest trace 166 ms (~500x lower). Per-vote work was unchanged, so the gap between votes was the problem, not the work |
| Heavy burst | 70,000 votes, still 1 `worker` | Queue passed 55,000 and kept growing; `worker` restarted. `db_write` stayed ~4 ms, so Postgres was not the limit. A single sequential consumer was |
| Fix 2 | KEDA scales `worker` on Redis list length | Queue peaked at ~3-5K and drained; ~250 votes/s sustained (~25x baseline); longest trace 8.18 s |

Scaling out then surfaced the next constraint: `worker`'s p99 processing time rose to ~200 ms once several
replicas shared one Redis and one Postgres.

Latencies above are **worst observed trace durations**, not p99 percentiles, and each row is a single run on a
small cluster: directional evidence, not a benchmark.

## What's built

- **CI/CD:** GitHub Actions with selective builds (only changed services) and release by retagging, never rebuilding
- **Infrastructure as code:** four Terraform stacks (below), built on the community `terraform-aws-modules`
- **GitOps:** Argo CD with self-healing and cascade teardown
- **Autoscaling at three layers:** HPA on CPU (`vote`, `result`), KEDA on queue depth (`worker`), Karpenter for nodes
- **Metrics:** Prometheus scraping all three apps, plus Redis and Postgres through sidecar exporters
- **Logs:** Loki, shipped by an Alloy DaemonSet, with no application changes required
- **Traces:** Tempo, fed by a second Alloy instance acting as the OTLP collector. `vote`, `worker` and `result`
  are instrumented with OpenTelemetry across Python, .NET and Node.js, including manual trace-context
  propagation across the Redis queue, which auto-instrumentation can't bridge

## Repo layout

- `app/` — the voting app services (vote, worker, result, redis, db)
- `infra/terraform/cluster/` — VPC, EKS cluster, managed node group, IAM, EBS CSI driver and the Karpenter
  IAM/SQS resources. AWS resources only.
- `infra/terraform/karpenter/` — cluster-wide platform prerequisites: Karpenter (controller, `NodePool`,
  `EC2NodeClass`), KEDA, `metrics-server`, and the `ebs-gp3` **StorageClass**. The StorageClass lives here
  deliberately — see [Build order](#build-order-matters).
- `infra/terraform/observability/` — `kube-prometheus-stack` (Prometheus, Grafana, Alertmanager), Loki, Tempo,
  and two Alloy instances (a DaemonSet shipping logs, a Deployment collecting traces)
- `infra/terraform/argocd/` — Argo CD install, plus the `Application` that watches `k8s/argocd/`
- `infra/terraform/app/` — first-pass Terraform-managed app deployment (frozen, no longer applied; superseded
  by Argo CD, kept for reference)
- `k8s/base/` — plain manifests for the local `kind` cluster
- `k8s/argocd/` — what Argo CD syncs on AWS: Deployments and Services with probes, HPAs for `vote`/`result`, a
  KEDA `ScaledObject` for `worker`, and the `ServiceMonitor`/`PodMonitor`s. This is the source of truth for
  what runs in the cluster.
- `.github/workflows/` — CI: selective build and push on push, retag-not-rebuild on release
- `scripts/` — `build-and-push.sh` and `traffic-generator.py` (phased load generator; edit `PHASES` to change its shape)
- `docs/` — plan, notes, diagrams

## Cluster sizing

The base node group is 2 x `m7i-flex.large`, kept as a standing buffer: a Karpenter-launched node takes
roughly 1-3 minutes to become Ready, so a burst shouldn't have to wait on a cold launch. Karpenter adds nodes
beyond that. The AWS account's Free Tier restriction limits which instance types can be launched at all, so the
`NodePool` is restricted to allowed types. Running this costs real money (EKS control plane, nodes, load
balancers), which is why the environment is destroyed between sessions.

## Local dev

```bash
cd app
docker compose up --build
```

Vote UI: http://localhost:8080 · Results UI: http://localhost:8081

Metrics endpoints: `:8080/metrics` (vote), `:8081/metrics` (result), `:9090/metrics` (worker).

Locally you'll see OTLP export errors in the `vote`/`worker`/`result` logs. They are expected and harmless:
the trace collector address is a cluster-internal DNS name that only resolves inside EKS.

## Build order matters

The layers depend on each other, and a from-scratch rebuild in the wrong order fails:

| Order | Directory | Why it goes here |
|---|---|---|
| 1 | `cluster/` | everything needs a cluster |
| 2 | `karpenter/` | node autoscaling, KEDA, `metrics-server`, and the StorageClass everything with a PVC needs |
| 3 | `observability/` | installs the `ServiceMonitor` CRDs; Loki and Tempo need the StorageClass from step 2 |
| 4 | `argocd/` | its manifests need the `ServiceMonitor` CRDs (step 3) and the KEDA `ScaledObject` CRD and StorageClass (step 2) |

The StorageClass used to live in `k8s/argocd/`, which created a circular dependency: Loki and Tempo needed it,
but it only existed once Argo CD had synced, while Argo CD's own manifests needed CRDs from `observability/`.
It now lives in Terraform in `karpenter/`, ahead of both.

## Rebuilding the AWS environment from scratch

```bash
cd infra/terraform/cluster && terraform apply
aws eks update-kubeconfig --name voting-app --region ap-south-2

cd ../karpenter && terraform apply -target=helm_release.karpenter_crd && terraform apply
cd ../observability && terraform apply
cd ../argocd && terraform apply -target=helm_release.argocd && terraform apply

kubectl get application -n argocd   # wait for Synced/Healthy
```

The `-target` applies install CRDs before the resources that depend on them (Terraform can't validate a custom
resource whose CRD doesn't exist yet). App images come from CI (`ghcr.io`), so they must already be built and pushed.

## Accessing the UIs

Grafana, Prometheus and Argo CD have no public endpoint, so use port-forwards:

```bash
# Grafana → http://localhost:3000 (admin password is a placeholder set in observability/kube-prometheus-stack.tf)
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80

# Prometheus → http://localhost:9090/targets
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090

# Argo CD → https://localhost:8080 (user: admin)
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

In Grafana, **Explore** has Prometheus, Loki and Tempo pre-provisioned as data sources. Traces link to logs by
service name.

`vote` and `result` each have their own LoadBalancer; `kubectl get svc vote result` shows the hostnames. To
generate load:

```bash
pip install requests
python scripts/traffic-generator.py --url http://<vote-elb-hostname>
```

## Tearing it down

Reverse of the build order. Argo CD's `selfHeal` will fight a plain `kubectl delete`, and several resources have
real AWS objects behind them (ELBs, EBS volumes, EC2 instances) that only get cleaned up if they're deleted
**while the cluster is still alive**.

```bash
kubectl delete application voting-app -n argocd   # cascade-deletes the app: cleans up its ELBs and db's EBS volume
kubectl get svc,pvc,pods                          # should be empty (apart from the built-in kubernetes Service)

cd infra/terraform/argocd && terraform destroy
cd ../observability && terraform destroy
kubectl get pvc -n observability                  # Loki/Tempo PVCs can outlive a helm uninstall — delete any leftovers
cd ../karpenter && terraform destroy              # while the cluster is alive, so Karpenter can terminate the nodes it launched
cd ../cluster && terraform destroy
```

Then verify directly in the AWS Console rather than trusting Terraform alone:

- **EC2 → Load Balancers** — none left
- **EC2 → Volumes** — nothing `available`/unattached (Loki's and Tempo's PVC volumes are the easy ones to miss)
- **EC2 → Instances** — no Karpenter-launched instances still running (they're not tracked in Terraform state)