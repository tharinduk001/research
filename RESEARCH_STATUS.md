# Research Status — AI-Driven Predictive Failure Detection

Living status document for the research side of the project. For *how to rebuild the
infrastructure*, see [SETUP_GUIDE.md](SETUP_GUIDE.md). For *how canary releases work
here*, see [CANARY_TRAFFIC_EXPLAINED.md](CANARY_TRAFFIC_EXPLAINED.md).

**Last updated:** 2026-07-25

---

## 1. Where the project stands

The infrastructure and observability phases are complete. Every signal the proposal
called for is instrumented, verified, and separable by deployment track. The next
phase is research proper: generating labelled data and building the prediction model.

| Phase | Status |
|---|---|
| Infrastructure (Terraform, GKE, CI/CD, canary) | Complete |
| Observability (metrics, logs, DB) | Complete |
| Realistic traffic (k6 load generator) | Complete |
| Baseline characterisation (3 no-fault deploys) | **Next** |
| Fault injection / dataset generation | Not started |
| Feature extraction collector | Not started |
| AI prediction engine | Not started |
| Decision engine | Not started |

---

## 2. Signal inventory (what is available to the model)

All application metrics carry a `track` label (`stable` / `canary`), which is what
makes canary-vs-stable comparison possible. See SETUP_GUIDE §19.4.

| Category | Examples | Source |
|---|---|---|
| HTTP | latency histograms per view/method, status codes, throughput, body sizes | `django_prometheus` (40 metrics) |
| Database (app side) | query count, query duration, new connections | `django_prometheus` DB backend |
| Database (server side) | active connections, locks, DB size, replication lag | `postgres_exporter` |
| Python runtime | resident memory, GC collections | `prometheus_client` defaults |
| Container | memory working set, **CPU throttling ratio** | cAdvisor / kubelet |
| Kubernetes | pod restarts, waiting/terminated reasons, readiness | kube-state-metrics |
| Logs | all pod stdout/stderr, auto-detected level | Loki + Promtail |

**Known gaps:**
- Logs have **no `track` label** (Promtail tags `app`, `pod`, `namespace`,
  `node_name`, `container`, `detected_level`). Separate tracks by pod name regex
  until this is configured.
- `django_http_exceptions_total_by_type_total` does not exist yet — it is a lazy
  counter that only appears after the first exception occurs. Expected, not a gap.
- Prometheus retention is **10 days**; the collector must persist feature vectors as
  it goes. Backfilling old deployments will not be possible.

---

## 3. Empirical findings

### 3.1 Cold-start bias is large and would break threshold-based analysis

Measured during the tag `6` rollout (2026-07-25), with only health-probe traffic:

| | stable | canary |
|---|---|---|
| p95 latency at pod start | 24.6 ms | **663 ms** (27× worse) |
| p95 latency at ~85 s | 24.6 ms | 44.8 ms |

The canary was **completely healthy** — the difference is entirely pod warmup (cold
caches, unwarmed DB connection pool, Django lazy imports).

**Implications:**
- Any static threshold (e.g. "roll back if p95 > 100 ms") would roll back a healthy
  deployment on *every* release, not occasionally.
- The CD bake period is 60 s and warmup takes roughly 60-90 s, so the pipeline makes
  its "step 1 passed" decision **while the pod is still warming up**. Early-window
  signal is dominated by warmup, not by code quality. This is a concrete mechanism
  explaining why threshold methods only catch failures late in a rollout.
- Canary was still 1.8× stable at 85 s, so **pod age is a genuine model feature**,
  not merely a filter/exclusion window.

### 3.2 Short windows are statistically sparse

Prometheus emitted `histogram_quantile` monotonicity warnings when computing
percentiles over short windows during the rollout — too few samples for reliable
quantile estimation. This is direct evidence that simple statistical tests are weak
inside the 60-120 s decision window, independent of the warmup problem above.

### 3.3 Traffic — resolved by the k6 load generator

Before: essentially **100% of traffic was health probes and metric scrapes**; no
user-facing view was exercised, so a broken canary could have looked healthy.

After (`k8s-manifests/load-generator.yaml`, ~25 iterations/s → ~50 req/s):

| | before | after |
|---|---|---|
| `home` | 0 | ~6.5/s |
| `login` | 0 | ~13/s |
| `register` | 0 | ~2.4/s |
| health probes | ~100% of traffic | ~2/s |
| DB queries | 0 | ~10.5/s |

### 3.4 App resource limits were broken (found by starting the load)

Starting the load generator immediately **OOMKilled all 5 pods** (exit 137). The cause
was pre-existing, not the load: the container runs 3 gunicorn workers × 6 threads
against a **128Mi** memory limit. It only survived previously because there was no
traffic. Had this been discovered later, every deployment in the dataset would have
been fighting an artificial memory ceiling.

CPU then became the bottleneck. Note the intermediate state — at a 1000m limit,
throttling sat at **56% while actual usage was only ~300m**, because 18 gunicorn
threads exhaust the CFS quota in bursts even at low average utilisation.

| | original | current |
|---|---|---|
| memory request/limit | 64Mi / 128Mi | 256Mi / 512Mi |
| cpu request/limit | 125m / 250m | 300m / 2000m |
| CPU throttling | 98% | **1.7%** |
| p95 latency | 207 ms | 42 ms |

**Why the throttling number matters:** CPU throttling ratio is one of the leading
indicator signals (§2). At a 56-98% baseline it is already saturated and a
CPU-related fault produces no visible rise. At 1.7% it is a usable signal.

### 3.4b Metrics were corrupted by multi-worker gunicorn (fixed, tag 7)

The app ran 3 gunicorn workers. django-prometheus keeps counters in **process** memory,
so each worker held its own, and `/metrics` was answered by whichever worker took the
scrape. Prometheus saw the counter drop on every worker switch, treated it as a reset,
and inflated `rate()` — reporting **9,500 req/s against an actual ~30 req/s** (~800x).

The error is **non-deterministic and grows over time** as workers diverge, so it could
not have been corrected for after the fact. Had it gone unnoticed, every deployment in
the dataset would have carried meaningless request-rate and latency figures.

Fixed by running a single worker with 8 threads (`--workers 1 --threads 8`). See
SETUP_GUIDE §21.4 for the detection command and why `PROMETHEUS_MULTIPROC_DIR` was not
used.

| | reported (corrupt) | actual |
|---|---|---|
| throughput | ~50 req/s | ~32 req/s |
| DB queries | ~10.5/s | ~7/s |
| memory per pod | ~135 Mi | ~62 Mi (1 worker, not 3) |

**Unaffected:** `container_*`, `kube_*`, `pg_*` are scraped independently of gunicorn.
All findings in §3.1 and §3.4 (cold-start bias, OOMKill, CPU throttling) therefore
stand — they rest on container-level metrics.

**Methodological note for the write-up:** aggregate percentiles happened to survive
roughly intact (p50/p95 barely moved) because `histogram_quantile` computes a *ratio*
across buckets, and all workers had similar distributions. That is luck, not
robustness — the histogram counts were just as corrupt.

### 3.5 Latency is bimodal — use per-view features, not aggregate

| | p50 | p95 | p99 |
|---|---|---|---|
| all views | 6.1 ms | 42 ms | **1.89 s** |
| `login` only | ~6 ms | 1.64 s | ~1.9 s |
| every other view | — | — | < 75 ms |

The entire p99 tail is the **login POST**. Django's password hasher (PBKDF2, ~600k
iterations) is deliberately expensive, and failed logins still pay full cost because
Django hashes a dummy password to prevent timing attacks.

**Consequence for feature engineering:** aggregate p95/p99 is driven by the *mix* of
fast GETs vs slow POSTs, not by application health — a slight shift in traffic mix
moves the aggregate percentile even when nothing is wrong. Model features must be
**per-view latency**, not aggregate latency.

---

## 4. Thesis framing

Working statement, sharpened by finding 3.1:

> Early-rollout signals are contaminated by pod warmup rather than code quality. A
> model that learns the expected warmup trajectory can subtract it and expose the
> real regression underneath — enabling reliable continue/rollback decisions inside
> the first 60-120 seconds, where static thresholds are unusable.

**Proposed contributions:**
1. Multimodal fusion (metrics **and** logs) for canary rollout prediction — existing
   tools (Kayenta, Flagger, Argo Rollouts analysis) are metrics-only; log-anomaly
   research is logs-only and not deployment-aware.
2. Log-template novelty as an early high-precision signal — a template appearing in
   canary but never in stable is strong evidence of regression, and surfaces before
   aggregate error rates move.
3. Warmup-aware analysis (motivated directly by finding 3.1).
4. Time-to-detection as a primary evaluation metric, not just accuracy.

---

## 5. Method for selecting signals

Which signals/combination work best is an experimental result, not a design choice.
**Collect wide, prune with data** — adding a metric to a query is free; re-running
200 deployments because one was missing is not.

Once labelled deployments exist:
1. **Univariate ranking** — per-feature AUC separating failed from successful deploys.
2. **Modality ablation** — metrics-only vs logs-only vs both. This directly tests
   contribution 1 and is the headline result.
3. **Early-detection curve** — discriminative power vs time. A feature that is 95%
   accurate at t=240 s is useless; 80% at t=45 s is valuable.
4. **Per-fault-type breakdown** — expected finding: no single signal covers all
   failure modes (memory leaks → RSS slope; bad migrations → logs/DB errors; slow
   endpoints → latency; crashes → restarts), which is itself the argument for fusion.

---

## 6. Planned fault catalogue (dataset generation)

Positives (injected faults): bad migration (missing column), memory leak, CPU hot
loop, unhandled exception in a view, injected endpoint latency, OOM via low memory
limit, boot crash (import error), broken DB credentials, Gunicorn worker timeout,
bad dependency pin, config drift (ALLOWED_HOSTS / CSRF).

Negatives: benign changes (text, CSS, harmless view). Include **hard negatives** —
benign deploys during load spikes — so the model does not learn "any anomaly =
failure."

---

## 7. Next steps

1. ~~Load generator~~ — done, see §3.3.
2. **Three no-fault deployments** to characterise the healthy-deploy baseline and the
   warmup curve precisely, before faults complicate interpretation. Commands:
   SETUP_GUIDE §14.
3. **Feature collector** — given a deployment start time, pull a wide time-windowed
   feature vector from Prometheus + Loki. Same code path for dataset building and
   live inference, to avoid train/serve skew. Must use **per-view** latency (§3.5)
   and record **pod age** (§3.1).
4. **Pilot dataset** (~20 deployments, 3-4 fault types) to validate the loop
   end-to-end before scaling.
5. Analysis (§5), then scale up and train.

Deferred, revisit when relevant:
- Add a `track` label to Promtail's log pipeline (§2) so logs can be compared
  canary-vs-stable the same way metrics already can.
- Session rows accumulate in Postgres from load-generator login POSTs (Django creates
  a session to store the failure message). Watch `pg_database_size_bytes`; add a
  `clearsessions` CronJob if growth becomes material.

---

## 8. Known limitations to state in the write-up

- **The dataset is synthetic.** Faults are injected, not organically occurring, and
  the application is a simple demo (homepage, login, register). This caps external
  validity and should be declared rather than glossed over.
- **Small sample size** (realistically 100-400 deployments) argues for gradient
  boosting over deep learning as the primary model, with Isolation Forest trained on
  stable-track behaviour only to sidestep label scarcity.
- **Single application, single cluster** — no evidence the model generalises across
  services or workloads.
- The canary mechanism is a GitHub Actions script rather than Argo Rollouts, so the
  decision engine must hook into workflow control rather than a rollout controller's
  native analysis API.
