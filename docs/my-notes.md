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

## Phase 3 continued — Terraform deploys the app itself (Reddit OP's pattern)

Destroyed and recreated cleanly (confirmed the fast rebuild loop works — ~10 minutes for the full cluster from scratch). Then split Terraform into two separate configs, `cluster/` and `app/`, after hitting a real bug: the `kubernetes`/`helm` providers, when configured using a *direct resource reference* to the cluster being created in the same run (`aws_eks_cluster.main.endpoint`), silently fell back to `localhost` instead of the real cluster — a documented chicken-and-egg provider-timing issue. Fixed by having `app/` use `data` source *lookups* ("find the cluster that already exists") instead of resource references, which resolved cleanly every time after.

Translated the Kubernetes manifests from the kind phase into native Terraform HCL (`kubernetes_deployment_v1`, `kubernetes_service_v1`, etc.) — same concepts, same tree shape, different syntax. `redis` first (simplest), confirming the whole provider chain worked before anything else depended on it.

**PVC support on EKS needed real setup, unlike kind's automatic `local-path-provisioner`:** required IRSA (IAM Roles for Service Accounts) — a narrower kind of IAM role than the node role, trusted only by a specific Kubernetes ServiceAccount via an OIDC identity provider registered against the cluster, rather than trusted by "any EC2 instance." Three pieces: the OIDC provider itself, the IAM role with that narrow trust policy, and installing the EBS CSI driver addon wearing that role. Chose `Delete` reclaim policy over `Retain` for the PVC's StorageClass — deliberately, since `Retain` would leave orphaned (still-billed) EBS volumes behind on every destroy, directly fighting the project's "destroy fast" goal, for data (vote counts) not worth protecting.

**Real bugs hit and fixed in this stretch:**
- `db`'s PVC deadlocked against its own Deployment: the StorageClass used `WaitForFirstConsumer` (correctly waits for a real Pod before creating the EBS volume, so it lands in the right AZ) — but Terraform's PVC resource defaults to waiting for `Bound` before creating anything that depends on it, including the very Deployment whose Pod would trigger binding. Fixed with `wait_until_bound = false` on the PVC.
- Postgres then failed to start with `initdb: directory exists but is not empty` — every freshly formatted EBS volume's ext4 filesystem includes a `lost+found` directory at its root, which `initdb` refuses to treat as empty. Fixed by pointing `PGDATA` at a subdirectory of the mount rather than the mount root itself.
- `t3.micro` nodes hit a hard pod-density ceiling (max 4 pods/node — a real AWS formula based on ENI/IP capacity, not a bug) — mandatory system Pods alone filled both nodes completely, leaving zero room for the EBS CSI controller or any app Pod. Fixed by moving to `t3.small` (11 pods/node), confirmed free-tier eligible for accounts created after July 2025 — initially assumed otherwise and was corrected.
- The `helm` provider failed with "cluster unreachable" — turned out to be a genuinely missing kubernetes auth block in that provider's config, not a provider-timing bug as first suspected. Worth remembering: check for the boring explanation before the exotic one, even when a symptom resembles a bug seen before.
- Path-based Ingress routing (`/vote`, `/result` on one shared Load Balancer) broke both apps' JS/CSS: their HTML references assets via *absolute* paths, which a path-rewrite can't retroactively fix inside already-served HTML. Fixed by giving `vote` and `result` each their own `type: LoadBalancer` Service instead — simpler and more reliable than chasing host-based routing via a Load Balancer's non-static IP, at the cost of a second small Load Balancer charge.

**Other real concepts learned:** IRSA vs. node-level IAM roles (workload-specific badge vs. shared node badge), Terraform's `helm_release` resource as a higher level of abstraction than raw HCL resources (delegates real complexity to a published chart), image tag passed as a Terraform *variable* (`-var="worker_image_tag=<sha>"`) rather than hardcoded — the actual mechanism matching the Reddit OP's "build once, promote via a variable" pattern — and `ImplementationSpecific` path types marking controller-specific (non-portable) Ingress behavior.

Whole app now running end-to-end on real AWS, fully provisioned via Terraform. Next: deliberately drift something on this live cluster and watch Terraform fail to notice, then bring in Argo CD.