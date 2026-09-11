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