# Voting App on Kubernetes

Learning project: take `dockersamples/example-voting-app`, understand it deeply, automate it,
and deploy it to Kubernetes with realistic scaling, GitOps, and full observability
(traces/logs/metrics) — all provisioned via Terraform.

Full plan and progress notes live in [`docs/project-plan.md`](docs/project-plan.md) — that file
is the source of truth; update it as decisions change.

## Repo layout

- `app/` — the voting app services (vote, worker, result, etc.)
- `infra/terraform/` — cluster, networking, Argo CD bootstrap, observability stack
- `k8s/` — manifests (what Argo CD reconciles against)
- `.github/workflows/` — CI: build + push images
- `scripts/` — automation scripts (build/package helpers, later the traffic generator)
- `docs/` — plan, notes, diagrams

## Status

Phase 0 — understanding the app locally. Not yet deployed anywhere.

## Local dev

```bash
cd app
docker compose up --build
```

Vote UI: http://localhost:8080 · Results UI: http://localhost:8081
