# Research Status — AI-Driven Predictive Failure Detection

Living status document for the research side of the project. For *how to rebuild the
infrastructure*, see [SETUP_GUIDE.md](SETUP_GUIDE.md). For *how canary releases work
here*, see [CANARY_TRAFFIC_EXPLAINED.md](CANARY_TRAFFIC_EXPLAINED.md).

**Last updated:** 2026-07-26

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
| Baseline characterisation (3 no-fault deploys) | Complete |
| Feature extraction collector | **Next** |
| Fault injection / dataset generation | Not started |
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

## 2b. Locked feature spec — what the collector extracts

Every feature is a **canary-vs-stable contrast at the same timestamp** (ratio or
delta), never an absolute value. Every HTTP/DB feature is **per-view**, never
aggregate (§3.5: aggregate cv > 1, per-view cv ≈ 0.003–0.007 — a ~300× difference in
usable signal). This is the target the feature collector is built against.

**Tier 1 — HTTP behaviour**
| Metric | Feature |
|---|---|
| `django_http_requests_latency_seconds_by_view_method_bucket` | p50/p95 latency per view |
| `django_http_responses_total_by_status_view_method_total` | error rate per view |
| `django_http_requests_total_by_view_transport_method_total` | throughput per view (also: sample count backing each percentile) |
| `django_http_requests_body_total_bytes_*` / `django_http_responses_body_total_bytes_*` | request/response size drift |

**Tier 2 — Database (app side + server side)**
| Metric | Feature |
|---|---|
| `django_db_execute_total` | query rate |
| `django_db_query_duration_seconds_bucket` | query latency percentile |
| `django_db_new_connections_total` | connection churn |
| `pg_stat_database_numbackends` | active server connections |
| `pg_locks_count` | lock contention |

**Tier 3 — Resource pressure (leading indicators)**
| Metric | Feature |
|---|---|
| `container_cpu_cfs_throttled_periods_total` / `container_cpu_cfs_periods_total` | CPU throttle ratio |
| `container_memory_working_set_bytes` | memory vs limit, and slope over the window |
| `process_resident_memory_bytes` | Python-process RSS, slope (leak detection) |
| `python_gc_collections_total` | GC rate |
| `kube_pod_container_status_restarts_total` | restart count |
| pod waiting/terminated `reason` | `CrashLoopBackOff` / `OOMKilled` / `Error` — near-free fault-type label |

**Tier 4 — Logs** (Loki; no `track` label yet — see gap above, use pod-name regex)
- Log-template novelty (Drain3): count of templates in canary absent from the stable
  baseline vocabulary — highest-value single log feature, surfaces before aggregate
  error rate moves
- `detected_level` distribution: INFO/WARN/ERROR counts per window
- String matches: `Traceback`, `OperationalError`/`ProgrammingError` (bad migration),
  `WORKER TIMEOUT`, `DisallowedHost`/CSRF (config drift)

**Tier 5 — Deployment context** (free, known at t=0)
- Migration file / `requirements.txt` / `settings.py` touched (bool each)
- Diff size, files changed
- Time since last deployment
- Current canary replica count (rollout step)
- Pod age (kept as a control variable despite §3.1's retraction — costs nothing,
  may matter on a heavier application)

**Deliberately excluded:** `pg_database_size_bytes`, `pg_replication_lag_seconds` —
too slow-moving for a 60–120s window; no replica exists in this setup so replication
lag is structurally always zero.

---

## 3. Empirical findings

### 3.1 Cold-start bias — WITHDRAWN, was a measurement artifact

**Originally claimed:** during the tag `6` rollout, canary p95 was 663 ms against
stable's 24.6 ms (27× worse) at pod start, implying pod warmup would defeat any static
threshold and motivating a "warmup-aware" model contribution.

**That claim is wrong.** It was measured when the system had only health-probe traffic,
so p95 was computed over a handful of requests and the first few cold ones dominated
it. It was sparse-data noise (§3.2) misread as a warmup curve.

Re-measured across **three clean deployments** (tags 8/9/10) with the load generator
running, `home` view p95 at the canary's first sample versus stable at the same instant:

| run | canary first sample | stable | difference |
|---|---|---|---|
| baseline 1 | 9.5 ms | 9.5 ms | 0% |
| baseline 2 | 9.6 ms | 9.5 ms | +1% |
| baseline 3 | 9.5 ms | 9.5 ms | 0% |

On aggregate (all-view) p95 the canary's first sample was actually **faster** than
stable in two of the three runs.

**Mechanism missed originally:** the pod has a `startupProbe` on `/start/` and a
`readinessProbe` on `/ready/` (every 5 s) that must pass *before* Kubernetes adds it to
the Service. Django is fully loaded and warm by the time real traffic reaches it —
warmup happens during the probe phase and never appears in request metrics.

**Methodological lesson for the write-up:** a 27× effect measured on one run of an
idle system should have been treated as suspect, not as a headline result. Conclusions
here need a minimum of three runs under representative load.

Residual open question: this app is trivial (template render, no cache priming, small
import graph). A heavier application with connection-pool ramp or cache warming could
still show a genuine effect. Not evidenced here, and should not be claimed without data.

### 3.2 Short windows are statistically sparse

Prometheus emitted `histogram_quantile` monotonicity warnings when computing
percentiles over short windows during the rollout — too few samples for reliable
quantile estimation. This is direct evidence that simple statistical tests are weak
inside the 60-120 s decision window, independent of the warmup problem above.

### 3.3 Traffic — resolved by the k6 load generator

Before: essentially **100% of traffic was health probes and metric scrapes**; no
user-facing view was exercised, so a broken canary could have looked healthy.

After (`k8s-manifests/load-generator.yaml`, ~25 iterations/s → ~32 req/s):

| | before | after |
|---|---|---|
| user-facing views (`home`, `login`, `register`) | 0 | ~30/s combined |
| health probes | ~100% of traffic | ~2/s |
| DB queries | 0 | ~7/s |

(Per-view figures measured under the corrupt-metrics regime were withdrawn; see §3.4b.
The `login` view receives disproportionately more requests than its 5% POST share
because k6 follows the post-failure redirect back to the login page.)

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

**Quantified across the three baseline deployments** (coefficient of variation =
sd/mean of p95 sampled every 15 s through the rollout; lower is a cleaner signal):

| | aggregate (all views) | `home` view only |
|---|---|---|
| baseline 1 canary / stable | 1.29 / 1.29 | **0.004 / 0.005** |
| baseline 2 canary / stable | 2.45 / 1.95 | **0.005 / 0.002** |
| baseline 3 canary / stable | 1.85 / 2.04 | **0.003 / 0.003** |

Choosing per-view over aggregate latency reduces baseline noise by roughly **300×**.
On aggregate, the standard deviation *exceeds the mean* (cv > 1) — a regression would
have to be enormous to be detectable. Per-view, cv ≈ 0.005, so a few-percent
regression is detectable.

This is the single most consequential feature-engineering decision found so far:
**granularity matters more than model sophistication.** No model can recover signal
from a cv > 1 feature that better feature selection makes trivially separable.

**Consequence for feature engineering:** aggregate p95/p99 is driven by the *mix* of
fast GETs vs slow POSTs, not by application health — a slight shift in traffic mix
moves the aggregate percentile even when nothing is wrong. Model features must be
**per-view latency**, not aggregate latency.

---

### 3.6 Healthy-deploy baseline profile (n=3, tags 8/9/11)

The reference a faulty deployment gets compared against. Recorded in
`data/deployments.csv`; regenerate with `scripts/run-deployment.sh clean`.

> **deploy_id=3 (tag 10) is marked EXCLUDED in the CSV, not deleted.** The load
> generator OOMKilled itself ~72s before that rollout ended (`discardResponseBodies`
> was not set, so k6 retained full response bodies per VU; as latency rose mid-rollout
> the VU count climbed toward `maxVUs` and memory followed). Traffic measurably dropped
> from ~31 to ~18 req/s during the affected window. Fixed in
> `k8s-manifests/load-generator.yaml` (bodies discarded by default, memory limit
> 256Mi→512Mi) and the run repeated cleanly as deploy_id=4 (tag 11, zero loadgen
> restarts). All figures below use deploy_id 1, 2, 4. This is itself a finding worth
> keeping: **the load generator is part of the measurement instrument and needs the
> same monitoring discipline as the system under test** — a silent 40% traffic drop
> would corrupt any deployment's features exactly like an injected fault would, and be
> indistinguishable from one without checking the generator's own health.

| Property | Value |
|---|---|
| rollout duration | 389 / 387 / 384 s (±0.5%) |
| outcome | success, rollback job skipped, all 3 (deploy_id 1, 2, 4 — see note below) |
| 5xx responses | **zero** — only 200 and 302 have ever been recorded |
| `home` p95, either track | 9.5 ms, sd < 0.1 ms |
| canary first sample vs stable | within 2% (§3.1) |
| aggregate p95 cv | 1.3-2.5 (unusable, §3.5) |
| per-view p95 cv | 0.002-0.007 (clean, §3.5) |

**Implication for labelling:** a clean deployment is extremely well-behaved — zero
errors, sub-1% duration variance, per-view latency stable to a fraction of a
millisecond. Separating clean from faulty should be easy for any reasonable model
*provided* the features are per-view. The research difficulty is therefore not
"detect the failure" but **detect it early, from the canary's small sample, before
the rollout proceeds** — which is where the 60-120 s window and the fusion of weak
signals actually matter.

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
3. ~~Warmup-aware analysis~~ — **withdrawn**, the motivating finding did not replicate
   (§3.1). Replaced by: **feature-granularity analysis** — per-view rather than
   aggregate signals reduce baseline noise ~300× (§3.5), which bounds the minimum
   detectable regression regardless of model choice.
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
