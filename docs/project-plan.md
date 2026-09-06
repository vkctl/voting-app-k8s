# Project Plan — example-voting-app on Kubernetes

**Goal:** Take `dockersamples/example-voting-app`, deeply understand it, automate its build/deploy, run it on Kubernetes with realistic scaling, and get full trace/log/metric visibility into a request's journey — all provisioned via Terraform, with fake traffic to make scaling and observability meaningful.

---

## Phase 0 — Understand the App (manual, no automation yet)
- Clone the repo, read `docker-compose.yml` end to end before running anything
- Run it with `docker compose up --build`, use it as a user (vote, watch result update)
- Inspect each hop by hand: exec into `redis` and watch the queue, `psql` into `db` and see what `worker` wrote
- Read each service's source (`vote`, `worker`, `result`) enough to know: what it talks to, what env vars/config it needs, what port it listens on
- **Output:** notes on the real data flow + a diagram you've drawn yourself (not copied from mine)

## Phase 1 — Manual Build & Package
- Build each service's Docker image by hand (`docker build`), without compose
- Run the containers individually, wire them up manually with `docker network` / `--link` equivalents, so you feel the pain compose was hiding from you
- Push images to a registry manually (Docker Hub or GHCR) — get the tagging/versioning scheme figured out by hand first
- **Output:** a shell script that does everything you just did manually, step by step (this is your first bit of automation, and you'll understand every line because you just did it by hand)

## Phase 2 — CI with GitHub Actions
- Repo on GitHub, Actions workflow triggered on push
- Steps: checkout → build each image → (optional) run any basic tests → push to registry with a meaningful tag (git SHA or semver)
- Keep it deliberately simple at first — just build+push, no deploy yet
- **Output:** green CI pipeline, images landing in your registry automatically on every push

## Phase 3 — Infrastructure Provisioning (Terraform)
- Provision a K8s cluster (cloud-managed — EKS/GKE/AKS, or local via kind/minikube for $0 first pass) + minimal networking
- Principles: everything reusable across environments (dev/staging), everything destroyable with one command, no manual console clicks
- Nothing app-specific yet — just the cluster itself and the bare minimum to reach it (ingress controller, maybe cert-manager)
- **Output:** `terraform apply` gives you a working empty cluster; `terraform destroy` cleans it up completely, no orphaned resources

## Phase 4 — Deploy: Single Instance of Everything (manual)
- Hand-write K8s manifests (or Helm chart) for vote/worker/result/redis/db, 1 replica each
- Deploy with plain `kubectl apply`, nothing automated
- Get end-to-end voting working inside the cluster, exposed via ingress
- No scaling, no observability yet — just "does the whole system work as intended on k8s"
- **Output:** a vote cast in the browser shows up in results, fully running in-cluster

## Phase 5 — Feel the Manual-Deploy Pain (deliberate)
- Do this *before* Argo CD, on purpose, so the pain is real and not just something I told you about
- Simulate a small "release": bump the image tag for `vote`, edit its manifest by hand, `kubectl apply`, confirm it worked
- Now simulate a release that touches **3 of the 5 services at once** — do it by hand, in order, with no tooling help
- Deliberately make (and then have to notice/fix) at least one mistake: forget to bump one manifest, apply things out of order, or apply to the wrong context
- Try to answer, using only what's in the cluster right now: "what's actually deployed, and does it match what's in git?" — notice how hard that is
- Try to roll back your last change without knowing off the top of your head what the previous image tag was
- **Output:** a written note (few bullet points, for yourself) of every papercut you hit — this becomes your personal case for Argo CD, not mine

## Phase 6 — GitOps with Argo CD
- Install Argo CD into the cluster (bootstrapped via Terraform)
- Point it at your repo's `k8s/` manifests — it continuously reconciles cluster state to match git
- Redo the exact same "3-service release" from Phase 5, but this time by committing to git and watching Argo CD apply it
- Deliberately edit something directly in the cluster with `kubectl` afterward and watch Argo CD detect and flag the drift
- Try a rollback — this time via git revert / Argo CD's UI, compare how it felt vs Phase 5
- **What this actually buys you (the short version, confirm it yourself in this phase):**
  - **Git becomes the single source of truth** — "what's deployed" is always answerable by reading a repo, not by inspecting a live cluster
  - **Drift detection** — someone (or something) changing the cluster directly outside git gets flagged, not silently left inconsistent
  - **Consistent multi-service releases** — one commit can represent "these 3 services move together," instead of you remembering the right order by hand
  - **Free rollback + audit trail** — `git revert` is your rollback mechanism, and `git log` is your deploy history, for free
  - **This scales to more services / more environments far better than your Phase 5 process did** — the pain you just felt with 5 services only gets worse with more
- **Output:** a side-by-side sense (from lived experience, not theory) of manual `kubectl apply` vs GitOps

## Phase 7 — Observability
- Instrument the services (start with whichever is easiest — likely `result` or `worker`) with OpenTelemetry
- Deploy Prometheus + Grafana + Loki + Tempo (or Jaeger) via Terraform/Helm
- Wire up Grafana trace→log correlation
- From here on, deploy config changes through Argo CD (git commit), not manual `kubectl apply` — keep using what you just built
- **Output:** cast a vote, find its trace in Grafana, click into its logs, see the DB write it caused

## Phase 8 — Scaling
- Add read replica(s) for Postgres, split `worker` (writes) vs `result` (reads) at the connection level
- Add HPAs: `vote` and `worker` on CPU/custom metrics; think through whether `result` needs a pub/sub layer to scale meaningfully (see earlier discussion)
- **Output:** manually spike load and watch pod counts change in real time

## Phase 9 — Fake Traffic / Load Simulation
- Build a small script/tool that casts votes at a controllable rate (constant, bursty, ramping)
- Use it to validate Phase 7 (do traces/dashboards tell a coherent story under load?) and Phase 8 (does scaling actually respond correctly?)
- **Output:** a load profile that reliably triggers scale-up, visible end-to-end in Grafana

---

## Open Decisions (flag these as we go, don't need answers now)
- Local cluster (kind/minikube, free) vs real cloud cluster (real cost, real cloud-provider behavior) — could do local first, cloud later
- Which observability signal to wire up first — I'd say metrics → logs → traces, since traces need the most instrumentation work
- Argo CD is now in the plan (Phase 6), deliberately preceded by a manual-pain phase (Phase 5) so the reasoning for adopting it comes from your own experience

---

**Not started yet — nothing to do right now.** Look this over, reorder/add/remove anything, and tell me what you'd change before we open Phase 0.
