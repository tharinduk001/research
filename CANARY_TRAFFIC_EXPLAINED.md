# How Canary Releases Actually Work Here

This document explains, in plain language, what physically happens inside the cluster
when a new release goes out — where pods run, how traffic gets split between old and
new versions, and what "promote" really does. It's a companion to
[SETUP_GUIDE.md](SETUP_GUIDE.md), written to answer a recurring point of confusion:
*"there are 2 nodes and a canary strategy — where do these pods actually go, and how
is traffic handled?"*

---

## 1. Two separate layers that are easy to conflate

**Nodes** are just compute. In this project there are 2 VMs (`e2-standard-4`) that
make up the cluster's total CPU/RAM budget. A node has no concept of "stable" or
"canary" — it's infrastructure, nothing more.

**Stable vs. canary** exists one layer above that, as two independent Kubernetes
**Deployment** objects in the `dev` namespace:

- `django-stable`
- `django-canary`

Each Deployment just says "keep N copies of this pod running." Nothing in a
Deployment specifies *which* node to use or *how much* traffic it should get.

## 2. Where pods actually land

When a Deployment needs a new pod, the Kubernetes **scheduler** looks at both nodes
and places the pod wherever there is free capacity at that moment — it never checks
whether the pod is "stable" or "canary." So at any given time, a stable pod and a
canary pod can sit on the *same* node, or be split across both. There is no "canary
node" and no "stable node." Both tracks share the same 2-node pool the entire time,
and the mix can shuffle between releases.

## 3. How traffic is actually split (no service mesh involved)

There's no Istio, no weighted routing rules, nothing that inspects percentages. The
only thing in front of the pods is `django-svc`, a plain Kubernetes Service whose
selector is:

```yaml
selector:
  app: django
```

Notice it does **not** say `track: stable`. That means `django-svc`'s list of valid
targets is the union of *every* pod from both Deployments — stable and canary pods
are completely indistinguishable to it. When a request comes in, it gets routed to
essentially a random pod out of everything currently matching.

So the "20% / 40% / 60%..." figures aren't a routing rule at all — they're **pure
population math**. If 5 pods exist total and 1 of them is canary, a random request
has roughly a 1-in-5 (20%) chance of landing on canary, simply because canary pods
make up 20% of the pool the Service picks from. Scale canary to 3-of-5 and the odds
become 60%. That's the entire strategy: **replica-count ratio, not traffic rules.**

## 4. The full request path

```
Browser
  → DNS (research.tharinduk001.com)
  → Static IP (34.54.199.53)
  → GCE Load Balancer (created by the GKE Ingress)
  → django-svc (ClusterIP, selector: app=django)
  → whichever pod is currently a healthy endpoint — stable or canary, on either node
```

## 5. Phase 1 — the canary ramp (gradual, one pod at a time)

This is driven by `cd.yaml`. Stable starts at 5 replicas, canary at 0. Each step
moves exactly one pod's worth in each direction, with a 60-second bake period after
every step so problems have a chance to surface before going further:

| Step | canary | stable | approx. traffic to new version |
|------|--------|--------|---------------------------------|
| 1 | 0 → 1 | 5 → 4 | 20% |
| 2 | 1 → 2 | 4 → 3 | 40% |
| 3 | 2 → 3 | 3 → 2 | 60% |
| 4 | 3 → 4 | 2 → 1 | 80% |
| 5 | 4 → 5 | 1 → 0 | 100% |

At every step, the scheduler places the new/removed pods on whichever node has room
— it is never told to prefer one node over the other.

## 6. Phase 2 — promote (instant, not gradual)

Once Step 5 has baked successfully (100% of traffic on the new version, no
failures), the pipeline does **not** repeat the one-by-one dance in reverse. It's
just two direct actions, done once:

1. `django-stable` — image updated to the new version, then scaled straight from
   **0 → 5** in a single move.
2. `django-canary` — scaled straight from **5 → 0** in a single move.

There's no need to ramp this slowly again — the new version already proved itself
at 100% real traffic during Step 5. Promote is just a relabeling/cleanup step: the
same running version keeps serving requests throughout, only which Deployment
"owns" the pods changes. `django-canary` ends up empty again, ready for the next
release to reuse.

Think of it like swapping the nameplate on a desk that's already occupied, rather
than making the person move desks.

## 7. If something goes wrong mid-rollout

If a canary pod fails its readiness probe or the bake period surfaces errors,
`cd.yaml`'s rollback path scales canary back to 0 and leaves stable exactly as it
was — the ramp simply reverses to the last known-good state instead of proceeding
to promote.

## 8. One thing that's *not* part of any of this

`postgres-0` (a separate StatefulSet, single pod) is shared unconditionally by both
`django-stable` and `django-canary` pods via `postgres-svc`. It isn't versioned,
isn't split, and has no role in the traffic-shifting story above — every pod, on
either track, on either node, talks to the same database.

## 9. Summary

- **Nodes** = compute hosts, interchangeable, no track affinity.
- **Deployments/pods** = a separate layer; "stable" and "canary" are just names on
  two independent pod groups that can land on either node.
- **`django-svc`** = the actual mechanism that makes both tracks eligible targets
  at once, via a selector that doesn't distinguish tracks.
- **"Percentage"** = an emergent result of replica-count ratio, not an explicit
  routing rule.
- **Ramp** = gradual, one pod at a time, with bake periods.
- **Promote** = instant, a one-shot label hand-off after the ramp already proved
  the new version at 100%.
