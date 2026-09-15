# Phase 0 Notes — Understanding `example-voting-app`

## Services (6 total)

| Service | Role | Ports | Networks | Depends on |
|---|---|---|---|---|
| `vote` | Python web app — casts a vote, pushes it to Redis | container `80` → host `8080` | `front-tier`, `back-tier` | `redis`, `db` (healthy) |
| `worker` | Pulls votes from Redis, writes them to Postgres | — (no exposed port) | `back-tier` | `redis`, `db` (healthy) |
| `result` | Polls Postgres every ~1s, broadcasts results to all connected Socket.IO clients | container `80` → host `8081` | `front-tier`, `back-tier` | `db` |
| `redis` | Queue — holds votes between `vote` and `worker` | internal only | `back-tier` | — |
| `db` | Postgres — stores votes | internal only | `back-tier` | — |
| `seed-data` | Load-testing helper (Apache Bench) that simulates concurrent votes against `vote` | — | — | not part of the runtime request path |

## Request Flow

```
vote (pushes to redis) → redis → worker (pops from redis, writes to db) → db → result (polls db, pushes via socket.io)
```

## How `worker` reads from Redis

`worker` runs a loop roughly every 100ms doing an async `LPOP` (list-pop) against the votes list in Redis, then attempts an insert into Postgres. If the insert fails because a row already exists for that voter, it falls back to an update.

**Why this is safe for scaling `worker` to multiple replicas:** Redis is single-threaded, so `LPOP` is atomic — if two `worker` replicas pop at nearly the same instant, Redis guarantees each pop returns a *different* item (or nothing). There's no race where two workers process the same vote. This means `worker` can safely run as N replicas polling the same list, with votes distributed across them.

**What the duplicate-handling logic is actually for:** it's not a concurrency safeguard — it's business logic. A voter can change their vote; when they do, a new message lands in Redis for a voter who already has a row in `db`. The insert-fails-so-fall-back-to-update pattern is how `worker` handles "this voter already voted, overwrite their choice" (one voter, two votes over time), not "two workers, one vote, at the same time." Worth keeping this distinction clear.

*Side note for later (not urgent):* catching an insert exception to trigger an update works, but Postgres's `INSERT ... ON CONFLICT DO UPDATE` (upsert) is the cleaner way to express this — avoids using exception handling as normal control flow. Something to consider if this service ever gets touched.

## Scaling Assessment

| Service | Scalable? | Reasoning |
|---|---|---|
| `vote` | ✅ Yes | Stateless, straightforward horizontal scaling |
| `redis` | ⚠️ Partially | Can run primary + replica for HA/failover, but this isn't a sharding/throughput win — it's a simple queue, not a scaled dataset |
| `worker` | ✅ Yes | Confirmed safe — Redis `LPOP` atomicity prevents double-processing across replicas |
| `result` | ⚠️ Yes, with a cost | Each replica runs its own independent 1s polling loop against `db`. Scaling `result` to N replicas means N× the DB read load, not free horizontal scaling. This is the concrete case for adding a pub/sub layer later (Phase 8) so replicas don't each hit the DB independently. |
| `db` | ✅ Yes, but not via HPA | 1 primary (writes) + read-only replicas. Replica count is a deliberate infra decision, never a reactive autoscale — spinning up a new replica requires a full base backup. |

## Open items carried into later phases
- Confirm `result`'s actual polling/broadcast behavior under multiple replicas once deployed (Phase 8)
- Consider whether `result` needs Redis pub/sub or a shared cache to avoid duplicated DB polling when scaled
- `seed-data`'s Apache Bench approach is a reference point for building a more purpose-built traffic generator later (Phase 9)

## Phase 3/4 — Local Kubernetes Deployment (summary)

Set up a local `kind` cluster and deployed all 5 services one at a time (redis → db → worker → vote → result), writing each manifest only after actually confirming how that service connects to its dependencies — this caught real things I'd have gotten wrong otherwise: `worker`, `vote`, and `result` all have hardcoded hostnames (`redis`, `db`) and hardcoded db credentials rather than reading env vars, and `result`'s listening port (`80`) isn't obvious from its own code — it's baked into its Dockerfile via `ENV PORT`, not visible in `docker-compose.yml` or `server.js` alone. Along the way, learned the core building blocks: Pods (disposable, managed via Deployments), Services (stable DNS name routing to whichever Pods are currently healthy, linked only via label matching), Secrets (base64-encoded, not encrypted — fine for now, needs real handling before AWS), PersistentVolumeClaims (only `db` needs one, since losing votes on restart would defeat the point), and Namespaces (organizational partitioning, not a security boundary by default).

Getting real browser access (rather than temporary `kubectl port-forward` tunnels) required installing an Ingress controller (`ingress-nginx`) and recreating the kind cluster with a config exposing ports 80/443 to the host — a good live example of "destroy and recreate fast" since the whole app came back in one `kubectl apply -f k8s/base/` command afterward. Final result: `vote.local` and `result.local` (via a hosts-file edit) route through one Ingress to the two front-facing services, and the full vote → redis → worker → db → result pipeline works end to end on a real (local) Kubernetes cluster.

## Phase 3 — AWS + Terraform (summary)

Moved to real AWS after getting comfortable on local kind — used an IAM user (not root) with access keys, `aws configure` to connect the CLI, then wrote Terraform incrementally, one piece at a time, reading every `plan` before applying: **networking** (VPC, 2 public subnets across 2 AZs — skipped NAT Gateways deliberately for speed/cost, accepting the trade-off of nodes having public IPs), **IAM roles** (two separate "badges" — a trust policy answering "who can assume this role" plus attached AWS-managed permission policies answering "what can it do once assumed" — one role for the EKS control plane, one for worker nodes), the **EKS cluster** itself (the managed control plane, ~$0.10/hr, took ~6 minutes to create), and the **node group** (the actual EC2 worker machines).

Considered using **AWS VPC IPAM** (hierarchical, structured CIDR allocation by environment/region/workload) instead of a hardcoded CIDR block — legitimate and used at real scale, but decided against it for this project specifically: provisioning a CIDR through IPAM can take up to 30 minutes and complicates teardown ordering, directly working against the "destroy/recreate fast" goal. Filed away as something to learn separately later, not inside this fast-iterating project.

**Real mistakes made and fixed, worth remembering:**
- Typo'd an EKS subnet discovery tag (`kubernetes.io/clusters/...` instead of `kubernetes.io/cluster/...`, singular) — Terraform didn't warn, because `tags` is just a generic string map to it; it has no idea AWS's own systems search for that exact key elsewhere. Same category of bug as the earlier `packages: write` GitHub Actions typo — syntactically valid, semantically wrong, nothing downstream flags it.
- First node group attempt used `t3.medium`, which failed with `InvalidParameterCombination` — the AWS account has **Free Tier usage restrictions** enabled, blocking any non-free-tier instance type. Not a capacity issue — an intentional account guardrail. Fixed by switching to `t3.micro` rather than disabling the restriction, since disabling it would remove a protection aligned with this project's own budget-consciousness.
- That failed node group got marked **"tainted"** by Terraform (created in AWS but never finished successfully) — Terraform's safe response to a tainted resource is destroy-then-recreate rather than trying to patch a half-built resource. The cleanup of that broken node group took ~16 minutes — notably slower than creating a clean one (~2 minutes) — a reminder that failure-path teardown isn't always as fast as the happy path, worth expecting rather than panicking over.

**Other concepts learned along the way:** `depends_on` (for ordering Terraform can't infer just from references — e.g. IAM policy attachments needing to exist before the cluster/node group that relies on them), Terraform automatically refreshing/diffing state against real AWS on every `plan`/`apply` (drift detection that only runs when explicitly invoked — not continuous, which is exactly the gap Argo CD is about to fill), and the distinction between node-group scaling (how many *machines* exist) versus Horizontal Pod Autoscaling (how many *Pod replicas* run) — two separate layers that both matter once real scaling work starts.

Next: destroy this environment cleanly, confirm it in the AWS console, then rebuild via `terraform apply` to prove the fast recreate loop — the actual reason all of this was built to be destroyable from day one.