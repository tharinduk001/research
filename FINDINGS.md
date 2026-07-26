# Findings — Signals for Failure Prediction

This document lists the metrics and logs chosen as input data for the AI model,
**why** each one was chosen, and **what test proved it works** (or, where nothing
has been tested yet, says so honestly).

For full technical detail see [RESEARCH_STATUS.md](RESEARCH_STATUS.md). This document
is the short, clean version.

---

## The one rule that applies to everything below

**Never look at a canary pod's number alone. Always compare it to what stable is
doing at the exact same moment.**

Why: traffic, time of day, and background load all move on their own. If you only
compare a number to yesterday's number, you can't tell whether a change means "the
new code is broken" or "it's just Tuesday afternoon." Comparing canary to stable
*at the same instant* cancels all of that out — both are getting the same traffic
mix, hitting the same database, running on the same nodes.

---

## 1. HTTP metrics — per page, never averaged across the whole app

**What:** latency and error rate, measured separately for each page (`home`,
`login`, `register`), not as one blended number for the whole site.

**Why:** different pages behave completely differently. The login page is naturally
slow (password checking is deliberately expensive) while the homepage is fast. If you
average them together, the average moves around depending on *how many people hit
login vs homepage in that minute* — not because anything is actually wrong.

**The test:** three clean (no-fault) deployments were run, and the "noisiness" of the
latency number was measured both ways — averaged across the whole site, and separately
per page.

**Result:**

| Measured as | How noisy (lower = better) |
|---|---|
| One number for the whole site | 1.3 – 2.5 |
| Separately per page | **0.003 – 0.007** |

Per-page is about **300 times less noisy**. On the blended number, the noise is
actually *bigger* than the average itself — meaning a real problem could easily hide
inside normal noise. Per-page, even a small, real change stands out clearly.

**Conclusion:** always measure per page. This was the single most important finding
in the whole project so far — it decides whether the model can see anything useful at
all.

---

## 2. Database metrics — from two different angles

**What:** how many database queries are happening and how long they take (measured
from the app's side), plus how many connections and locks the database itself has
open (measured from the database's side).

**Why:** these two angles catch different problems. A bad database migration shows up
as errors *on the app side* — the app is asking for something that doesn't exist. A
connection leak or a runaway process shows up as pressure *on the database side* — too
many open connections — even if the app itself isn't reporting errors yet. Watching
only one side would miss the other failure type entirely.

**The test:** database metrics were not available at all at first — the standard
Django setup doesn't report anything. A change was made to turn on measurement from
the app's side, and a separate small tool was added to measure the database server
itself. Both were then checked to confirm they were actually working (not just
switched on, but actually receiving real numbers).

**Result:** confirmed both are live and reporting real numbers — for example, the
database tool successfully reported "2 active connections" and "10.5 GB database
size," proving it was really talking to the database, not just running.

**Conclusion:** keep both. They are cheap to collect and cover two different failure
types that neither one alone would catch.

---

## 3. Resource metrics — CPU and memory pressure

**What:** how much of its CPU allowance a pod is being throttled (stopped from
running) and how close it is to its memory limit.

**Why:** these often move *before* a user notices anything. A memory leak shows up as
memory climbing steadily long before the app actually crashes. A CPU problem shows up
as throttling before requests start timing out. Catching the *lead-up* rather than the
*crash* is exactly what "predicting failure before it happens" means.

**The test:** this one wasn't found by careful planning — it was found by an actual
incident. When real traffic was first sent to the app, **every single pod crashed
immediately** from running out of memory. Investigating why revealed the app's memory
limit had always been too small — it had just never been tested under real load
before. After fixing the memory limit, a second problem appeared: CPU throttling was
stuck at a high 56%, even though actual CPU usage looked low. That turned out to be a
quirk of how multiple worker threads use CPU in short bursts. The CPU limit was raised
further to fix it.

**Result — before and after:**

| | Before fix | After fix |
|---|---|---|
| Pods survive real traffic | No — crashed instantly | Yes |
| CPU throttling (idle baseline) | 56–98% | **~2%** |

**Why this matters for the model specifically:** if throttling normally sits at 56%,
a real CPU problem can't push it much higher — there's no room left to show a change.
Once the baseline was pushed down to ~2%, a genuine CPU-related fault would now be
clearly visible.

**Conclusion:** these signals are only useful once the system is healthy enough that
they sit near zero normally. Fixing that healthy baseline was a necessary step, not
an optional one.

---

## 4. Logs — new error messages that only appear on the new version

**What:** watching for log messages during a canary release that have never appeared
in the stable version's history, plus simple counts of error/warning messages.

**Why:** a brand-new error message — one that has never shown up before — is very
strong evidence something is wrong with the new code, and it can appear *immediately*,
before enough failed requests have piled up to move any percentage-based number.
Numbers need volume to become reliable; a single distinctive new error message
doesn't.

**The test:** this one is **reasoning, not yet a proven result.** No real fault has
been deliberately introduced into the system yet, so there is no case on record where
a new error message appeared and was caught this way. The idea is well supported by
how the system is known to behave, but it still needs to be tested once fault
injection begins.

**Conclusion:** included as a planned signal, honestly labelled as *not yet tested*.

---

## 5. Deployment context — what changed, before any traffic is even sent

**What:** simple facts about the change itself — did it touch a database migration
file, a settings file, or the dependency list? How big is the change? How long since
the last release? Which stage of the gradual rollout is currently active?

**Why:** these cost nothing to collect (they come from the code change itself, not
from watching traffic) and give the model a head start. A change that only edits a
homepage headline is inherently much less risky than one that changes the database
schema — knowing that in advance helps the model weigh the other signals correctly.

**The test:** not yet tested with real data either — same honest caveat as logs above.
It is a standard, low-cost addition, but its actual usefulness will only be confirmed
once real deployments (clean and faulty) are collected and compared.

**Conclusion:** included as a cheap, logical addition. Value not yet measured.

---

## Summary table

| Category | Status | Confidence |
|---|---|---|
| HTTP metrics (per page) | Tested on 3 real deployments | **Proven** — 300x noise reduction measured |
| Database metrics | Tested — confirmed both sources report real data | **Proven working**, not yet tested against a real fault |
| Resource metrics (CPU/memory) | Tested — real incident found, fixed, re-measured | **Proven** — before/after numbers recorded |
| Logs (new error messages) | Reasoning only | Not yet tested |
| Deployment context | Reasoning only | Not yet tested |

Three of five categories have real evidence behind them, from real deployments run on
the actual system. Two are sound in logic but still waiting on fault-injection testing
to confirm they help in practice. That testing is the next step.
