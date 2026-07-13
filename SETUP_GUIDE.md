# Canary Deployment Infrastructure — Setup Guide

This document records **every step taken** to go from a bare repository to a fully working,
live canary-deployment pipeline (Django app → Docker → GKE → Terraform → GitHub Actions CI/CD).
Follow it top to bottom to rebuild the project from scratch without AI assistance.

> **Security note:** This is a research/demo project. Several values below (DB passwords, Django
> `SECRET_KEY`) are checked into the repo in plain text (`k8s-manifests/secrets.yaml`,
> `helm-charts/deployments/values.yaml`) — this was already the case in the original repo design.
> Do not reuse these values for anything production-facing. Rotate them if this ever becomes a
> real deployment.

---

## 0. Reference values (fill in your own, keep this table updated)

| Item | Value used in this build |
|---|---|
| GCP Project ID | `research-502304` |
| GCP Project Number | `535060614688` |
| Billing account | `01A666-C23700-A4F501` |
| Region / Zone | `us-central1` / `us-central1-a` |
| Domain | `research.tharinduk001.com` (managed on Vercel DNS) |
| Static IP name / address | `k8s-test` / `34.54.199.53` |
| VPC / Subnet | `research-vpc` / `research-subnet` (`10.10.0.0/24`) |
| GKE cluster / node pool | `research-gke` / `research-node-pool` |
| Node machine type | `e2-standard-4` (see §9 for why not `e2-medium`) |
| Artifact Registry repo | `us-central1-docker.pkg.dev/research-502304/canary-repo` |
| Image name | `canary-app` |
| Terraform state bucket | `gs://research-502304-tfstate` |
| WIF pool / provider | `github-pool` / `github-provider` |
| Deployer service account | `gh-actions-deployer@research-502304.iam.gserviceaccount.com` |
| GitHub repo | `tharinduk001/research` |
| GKE node default SA | `535060614688-compute@developer.gserviceaccount.com` |
| Monitoring namespace | `monitoring` |
| Loki Helm release name | `loki` (chart `grafana/loki-stack`) |

---

## 1. Prerequisites

Install locally: `docker` + `docker compose`, `gcloud` CLI (with `gke-gcloud-auth-plugin`),
`kubectl`, `terraform` (1.11.4+ recommended, we used 1.15.7 locally), `gh` (GitHub CLI), `git`.

You need:
- A GCP project with billing enabled.
- A domain you control (here: `tharinduk001.com`, using the `research` subdomain).
- Push access to the GitHub repo (`tharinduk001/research`).

Authenticate the CLIs once, interactively, in your own terminal:
```bash
gcloud auth login                              # your Google identity
gcloud config set project research-502304
gh auth login                                   # your GitHub identity (choose HTTPS, browser login)
```

---

## 2. Domain wiring (code changes)

The app and manifests hardcode a domain in a few places. Point them at your own domain.

**`k8s-manifests/ingress.yaml`** — line with `host:`:
```yaml
    - host: research.tharinduk001.com
```

**`k8s-manifests/cert.yaml`** — under `spec.domains`:
```yaml
  domains:
    - research.tharinduk001.com
```

**`helm-charts/deployments/values.yaml`** — under `ingress` and `certificate`:
```yaml
ingress:
  ...
  host: research.tharinduk001.com

certificate:
  name: django-mc
  domain: research.tharinduk001.com
```

**`demo-application/simply/settings.py`** — CSRF trusted origins (required, otherwise
POST requests like login/register fail over HTTPS):
```python
CSRF_TRUSTED_ORIGINS = ['https://research.tharinduk001.com']
```

---

## 3. GCP project bootstrap

Enable the APIs Terraform/CI/CD need:
```bash
gcloud services enable compute.googleapis.com container.googleapis.com artifactregistry.googleapis.com \
  --project=research-502304
```

Create the Docker image repository (Artifact Registry):
```bash
gcloud artifacts repositories create canary-repo \
  --project=research-502304 \
  --location=us-central1 \
  --repository-format=docker \
  --description="Canary deployment demo app images"
```

Create the GCS bucket that will hold Terraform remote state:
```bash
gsutil mb -p research-502304 -l us-central1 gs://research-502304-tfstate
```

Reserve a **global static IP** for the GKE Ingress (the manifests reference this by name,
`k8s-test`, via the `kubernetes.io/ingress.global-static-ip-name` annotation):
```bash
gcloud compute addresses create k8s-test --global --project=research-502304
gcloud compute addresses describe k8s-test --global --project=research-502304 --format="value(address)"
# -> 34.54.199.53
```

Add a DNS record at your domain registrar/DNS provider pointing your subdomain at that IP:
```
Type: A
Name: research
Value: 34.54.199.53
```

---

## 4. Keyless GitHub Actions authentication (Workload Identity Federation)

Instead of a long-lived GCP service-account key file, GitHub Actions authenticates via OIDC.
Only workflow runs from the exact repo `tharinduk001/research` can use this.

```bash
# 1. Create the identity pool
gcloud iam workload-identity-pools create "github-pool" \
  --project="research-502304" \
  --location="global" \
  --display-name="GitHub Actions Pool"

# 2. Create the OIDC provider, scoped to this repo only
gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project="research-502304" \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --display-name="GitHub Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository=='tharinduk001/research'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# 3. Create the deployer service account
gcloud iam service-accounts create gh-actions-deployer \
  --project="research-502304" \
  --display-name="GitHub Actions Deployer"

# 4. Grant it the roles Terraform / CI / CD actually need
SA="gh-actions-deployer@research-502304.iam.gserviceaccount.com"
for ROLE in roles/container.admin roles/compute.networkAdmin roles/compute.securityAdmin \
            roles/artifactregistry.writer roles/storage.admin roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding research-502304 \
    --member="serviceAccount:$SA" \
    --role="$ROLE" \
    --condition=None
done

# 5. Allow the GitHub repo's WIF identity to impersonate that service account
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --project="research-502304" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/535060614688/locations/global/workloadIdentityPools/github-pool/attribute.repository/tharinduk001/research"
```

Note the full WIF provider resource name (needed for the `WIF_PROVIDER` secret later):
```bash
gcloud iam workload-identity-pools providers describe github-provider \
  --project="research-502304" --location="global" --workload-identity-pool="github-pool" \
  --format="value(name)"
# -> projects/535060614688/locations/global/workloadIdentityPools/github-pool/providers/github-provider
```

### Code changes to use OIDC everywhere

**`terraform/provider.tf`** — remove the static `key.json` credentials reference entirely
(rely on Application Default Credentials instead), and point the backend at the real bucket:
```hcl
terraform {
  backend "gcs" {
    bucket = "research-502304-tfstate"
    prefix = "terraform/state"
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.33.0"
    }
  }
}

provider "google" {
  project = var.project_id
}
```

**`.github/workflows/terraform.yaml`** — replace the "write key.json from a secret" step with
an OIDC auth step, and drop the "remove credentials file" step:
```yaml
permissions:
  contents: read
  id-token: write

jobs:
  terraform:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: ./terraform
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Authenticate to Google Cloud (OIDC)
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.WIF_PROVIDER }}
          service_account: ${{ secrets.WIF_SERVICE_ACCOUNT }}
          create_credentials_file: true

      - name: Set up Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.11.4

      # ... terraform init / plan / apply steps unchanged, still pass TF_VAR_* from secrets
```
(`ci.yaml` and `cd.yaml` already used OIDC in the original repo — no change needed there beyond
the image-path fix in §5.)

---

## 5. Reconcile CI/CD image paths

The original repo had a mismatch: `ci.yaml` builds/pushes using `secrets.GAR_REPOSITORY` and a
hardcoded image name `canary-app`, but `cd.yaml` was reading `secrets.GAR_REPO` +
`secrets.IMAGE_NAME` — different secret names, so CD would pull a non-existent image.

**`.github/workflows/cd.yaml`** — fix the `IMAGE` env var to match `ci.yaml`:
```yaml
env:
  IMAGE: ${{ secrets.GAR_REGION }}-docker.pkg.dev/${{ secrets.GCP_PROJECT_ID }}/${{ secrets.GAR_REPOSITORY }}/canary-app
```

### Bootstrap image references

The manifests initially pointed at a placeholder Docker Hub image (`duvindune/repo1:v1`).
Point them at the real Artifact Registry path instead (tag `1` = the first CI build):

**`k8s-manifests/stable-deployment.yaml`** and **`k8s-manifests/canary-deployment.yaml`**:
```yaml
          image: us-central1-docker.pkg.dev/research-502304/canary-repo/canary-app:1
```

**`helm-charts/deployments/values.yaml`**:
```yaml
stable:
  name: django-stable
  replicas: 5
  image:
    repository: us-central1-docker.pkg.dev/research-502304/canary-repo/canary-app
    tag: "1"

canary:
  name: django-canary
  replicas: 0
  image:
    repository: us-central1-docker.pkg.dev/research-502304/canary-repo/canary-app
    tag: "1"
```

(These pods will sit in `ImagePullBackOff` until CI has actually run once and pushed tag `1` —
see §12. This is expected.)

---

## 6. Terraform variables

Create `terraform/terraform.tfvars` (this file is gitignored — `terraform/*.tfvars` — so it
must be created locally/manually, it is **not** committed):

```hcl
project_id = "research-502304"
region     = "us-central1"
zone       = "us-central1-a"

vpc_name    = "research-vpc"
subnet_name = "research-subnet"
subnet_cidr = "10.10.0.0/24"

cluster_name   = "research-gke"
node_pool_name = "research-node-pool"
node_count     = 2
machine_type   = "e2-standard-4"
disk_type      = "pd-standard"
disk_size      = 30
image_type     = "COS_CONTAINERD"
```

> **`machine_type` is `e2-standard-4`, not the smaller `e2-medium`.** See §9 for why — the
> smaller type does not leave enough CPU headroom for the app once GKE's own system pods are
> accounted for.

---

## 7. GitHub repository secrets

All three workflows (`ci.yaml`, `cd.yaml`, `terraform.yaml`) read configuration from repo
secrets. Set all 19 (note: `terraform.yaml` uses `PROJECT_ID`/`REGION`/`ZONE` while `ci.yaml`/
`cd.yaml` use `GCP_PROJECT_ID`/`GAR_REGION` — different names, same values, a naming quirk
already present in the original workflow files that was left as-is):

```bash
REPO="tharinduk001/research"

gh secret set WIF_PROVIDER --repo "$REPO" --body "projects/535060614688/locations/global/workloadIdentityPools/github-pool/providers/github-provider"
gh secret set WIF_SERVICE_ACCOUNT --repo "$REPO" --body "gh-actions-deployer@research-502304.iam.gserviceaccount.com"
gh secret set GCP_PROJECT_ID --repo "$REPO" --body "research-502304"
gh secret set PROJECT_ID --repo "$REPO" --body "research-502304"
gh secret set GAR_REGION --repo "$REPO" --body "us-central1"
gh secret set GAR_REPOSITORY --repo "$REPO" --body "canary-repo"
gh secret set GKE_CLUSTER_NAME --repo "$REPO" --body "research-gke"
gh secret set GKE_ZONE --repo "$REPO" --body "us-central1-a"
gh secret set REGION --repo "$REPO" --body "us-central1"
gh secret set ZONE --repo "$REPO" --body "us-central1-a"
gh secret set VPC_NAME --repo "$REPO" --body "research-vpc"
gh secret set SUBNET_NAME --repo "$REPO" --body "research-subnet"
gh secret set SUBNET_CIDR --repo "$REPO" --body "10.10.0.0/24"
gh secret set CLUSTER_NAME --repo "$REPO" --body "research-gke"
gh secret set NODE_POOL_NAME --repo "$REPO" --body "research-node-pool"
gh secret set NODE_COUNT --repo "$REPO" --body "2"
gh secret set MACHINE_TYPE --repo "$REPO" --body "e2-standard-4"
gh secret set DISK_TYPE --repo "$REPO" --body "pd-standard"
gh secret set DISK_SIZE --repo "$REPO" --body "30"
gh secret set IMAGE_TYPE --repo "$REPO" --body "COS_CONTAINERD"
```

Verify:
```bash
gh secret list --repo tharinduk001/research
```

---

## 8. Local test with docker-compose (do this before touching the cloud)

Create `.env` in the repo root (this file is gitignored, never commit it):
```
DB_USER=appuser
DB_PASS=<pick-a-local-password>
DB_NAME=db
DB_HOST=db
DB_PORT=5432
SECRET_KEY=<random-long-string>
```
Generate a random secret key if needed:
```bash
openssl rand -base64 50 | tr -d '\n'
```

Run the stack:
```bash
docker compose up --build -d
docker compose ps                       # both containers should become "healthy"
curl -s http://localhost:8000/health/   # -> "Health OK"
curl -s http://localhost:8000/start/    # -> 200
curl -s http://localhost:8000/ready/    # -> 200
curl -s http://localhost:8000/live/     # -> 200
curl -s http://localhost:8000/          # homepage should render
```
Tear down when done:
```bash
docker compose down
```

---

## 9. Provision cloud infrastructure with Terraform

### 9.1 Local credentials
Terraform (run locally) needs Application Default Credentials, since `provider.tf` no longer
references a key file:
```bash
gcloud auth application-default login
```
**Important:** also set the ADC *quota project* explicitly — otherwise Terraform's Cloud
Storage backend calls may be billed/quota-checked against whatever project happens to be your
`gcloud config`'s active project, not the one you actually want:
```bash
gcloud auth application-default set-quota-project research-502304
```

### 9.2 Init, plan, apply
```bash
cd terraform
terraform init
terraform plan     # review: should show 8 resources to add (vpc, subnet, 4 firewalls, cluster, node pool)
terraform apply -auto-approve
```
This takes roughly 10 minutes (the GKE cluster itself takes ~7 minutes, the node pool ~2 minutes).

Resources created: `google_compute_network.vpc`, `google_compute_subnetwork.subnet`,
4× `google_compute_firewall` (ICMP, SSH/22, HTTP/80, HTTPS/443 — all open from `0.0.0.0/0`,
this is the original repo's network design, left unchanged), `google_container_cluster.primary`,
`google_container_node_pool.custom_pool`.

### 9.3 Why `e2-medium` doesn't work (do NOT use it)

If you provision with `machine_type = "e2-medium"` (2 vCPU, shared-core/burstable), you will
find pods stuck `Pending` (`Insufficient cpu`) and others in `ImagePullBackOff`-adjacent scheduling
failures. The cause: GKE's own mandatory system pods per node — `kube-dns`, `fluentbit-gke`
(logging), `gke-metrics-agent`, `konnectivity-agent`, `kube-proxy`, `node-local-dns`,
`pdcsi-node` (CSI driver), `metrics-server` — already consume **~900m of the node's ~940m
allocatable CPU**, leaving almost nothing for your own pods, regardless of how small your app's
resource requests are.

Diagnose this yourself with:
```bash
kubectl describe nodes | grep -A5 "Allocatable:"
kubectl describe nodes | grep -B2 -A15 "Allocated resources:"
```

Fix: use a machine type with more vCPUs so the fixed ~900m system-pod overhead becomes a smaller
fraction of the total. `e2-standard-4` (4 vCPU, dedicated/non-burstable) gives ~3920m allocatable
per node — comfortably fits the demo workload (up to 10 app pods transiently during a canary
rollout + Postgres).

If you need to resize an existing node pool:
```bash
# edit terraform/terraform.tfvars: machine_type = "e2-standard-4"
cd terraform
terraform plan     # shows: node pool "update in-place", 0 add / 1 change / 0 destroy
terraform apply -auto-approve   # GKE recreates nodes with the new machine type, ~9-10 min
```

---

## 10. Grant GKE nodes permission to pull images

By default, GKE nodes run as the project's default Compute Engine service account
(`<PROJECT_NUMBER>-compute@developer.gserviceaccount.com`), which has **no** access to your
Artifact Registry repo unless you grant it. Without this, every pod fails to pull with a
"not found" error even though the image exists (a permissions error masquerading as "not found").

```bash
gcloud artifacts repositories add-iam-policy-binding canary-repo \
  --project=research-502304 \
  --location=us-central1 \
  --member="serviceAccount:535060614688-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"
```

---

## 11. Connect kubectl and bootstrap the cluster

```bash
gcloud container clusters get-credentials research-gke --zone us-central1-a --project research-502304
kubectl get nodes     # both nodes should be "Ready"
```

Apply the manifests **in this order** (dependencies matter — namespace first, secret before
anything that references it, Postgres before the app):

```bash
cd /path/to/Research     # repo root

kubectl apply -f k8s-manifests/namespace.yaml

kubectl apply -f k8s-manifests/secrets.yaml

kubectl apply -f k8s-manifests/headless-svc.yaml -f k8s-manifests/statefulset.yaml
kubectl rollout status statefulset/postgres -n dev --timeout=180s

kubectl apply -f k8s-manifests/app-svc.yaml \
               -f k8s-manifests/stable-deployment.yaml \
               -f k8s-manifests/canary-deployment.yaml

kubectl apply -f k8s-manifests/cert.yaml -f k8s-manifests/ingress.yaml
```

At this point `django-stable` pods will be `Pending`/`ImagePullBackOff` because tag `1` doesn't
exist in Artifact Registry yet — that's expected until the next step.

(Alternative: `helm-charts/deployments/` is an equivalent, parameterized Helm chart mirroring
the same manifests — `helm install django-app helm-charts/deployments -n dev` — only one of the
two deployment methods is needed, this guide used the raw manifests.)

---

## 12. Build and push the first image (CI)

```bash
gh workflow run ci.yaml --repo tharinduk001/research
gh run list --repo tharinduk001/research --workflow=ci.yaml --limit 1   # get the run id
gh run watch <run-id> --repo tharinduk001/research --exit-status
```
This builds `./demo-application` and pushes
`us-central1-docker.pkg.dev/research-502304/canary-repo/canary-app:<github.run_number>`.
The very first run produces tag `1`, matching the bootstrap manifests from §5 — no manual image
update is needed; the already-`Pending`/`ImagePullBackOff` pods will self-heal once the image
exists (Kubernetes retries with backoff automatically).

Verify:
```bash
gcloud artifacts docker images list us-central1-docker.pkg.dev/research-502304/canary-repo --include-tags
kubectl get pods -n dev
```

---

## 13. Verify the full stack is live

```bash
kubectl get pods -n dev                      # postgres-0 + 5x django-stable, all Running/1/1
kubectl get ingress -n dev                   # ADDRESS should show 34.54.199.53
kubectl get managedcertificate -n dev         # STATUS should eventually show "Active"
                                               # (can take 15-60 min after DNS resolves)
curl -s -o /dev/null -w "%{http_code}\n" https://research.tharinduk001.com/health/   # -> 200
```

---

## 14. Run a canary deployment (the actual CD cycle)

This is the repeatable release process. Every time you want to ship a change:

1. **Make your code change** in `demo-application/`.
2. **Commit and push to `main`:**
   ```bash
   git add <changed files>
   git commit -m "your message"
   git push origin main
   ```
3. **Build the new image (CI):**
   ```bash
   gh workflow run ci.yaml --repo tharinduk001/research
   gh run list --repo tharinduk001/research --workflow=ci.yaml --limit 1   # note the run id and number
   gh run watch <run-id> --repo tharinduk001/research --exit-status
   ```
   The GitHub Actions run number (visible via
   `gh run view <run-id> --repo tharinduk001/research --json number`) is the image tag just built.
4. **Trigger the canary rollout (CD):**
   ```bash
   gh workflow run cd.yaml --repo tharinduk001/research -f image_tag=<N> -f namespace=dev
   gh run list --repo tharinduk001/research --workflow=cd.yaml --limit 1   # note the run id
   gh run watch <run-id> --repo tharinduk001/research --exit-status
   ```

### What the CD workflow actually does (`.github/workflows/cd.yaml`)

There is **no service mesh** — traffic split is achieved purely by the **replica ratio**
between two Deployments (`django-stable` and `django-canary`) that both sit behind the same
`django-svc` (selector `app: django`, not track-specific). The workflow:

1. Records the current `django-stable` image (for rollback).
2. Sets `django-canary`'s image to the new tag.
3. **Step 1 (20%):** scale stable→4, canary→1, wait for canary rollout, sleep 60s.
4. **Step 2 (40%):** stable→3, canary→2, wait, sleep 60s.
5. **Step 3 (60%):** stable→2, canary→3, wait, sleep 60s.
6. **Step 4 (80%):** stable→1, canary→4, wait, sleep 60s.
7. **Step 5 (100%):** stable→0, canary→5, wait.
8. **Promote:** set `django-stable`'s image to the new tag, scale it back to 5, wait for its
   rollout, then scale `django-canary` back to 0.

If any `kubectl rollout status` step fails, the workflow's `canary-rollout` job fails and a
separate `rollback` job (`if: failure()`) automatically resets `django-stable` to the
previously-recorded image at 5 replicas and scales canary to 0.

Total run time for a full rollout: ~7-8 minutes.

---

## 15. How to monitor a canary rollout in progress

```bash
# Live replica ratio, per track
kubectl get pods -n dev -l app=django -L track -w

# Deployment-level view
kubectl get deployments -n dev

# Watch the GitHub Actions run itself
gh run watch <run-id> --repo tharinduk001/research

# Which image each track is currently running
kubectl get deployment django-stable -n dev -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl get deployment django-canary -n dev -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# See the live site responding (useful if your change is visible, e.g. homepage text)
curl -s https://research.tharinduk001.com/
```

---

## 16. Known pre-existing quirks (intentionally left unchanged)

These were present in the original repository design and were **not** modified, per the
project's "don't change beyond what's needed" constraint:

- **Firewall rules are open to `0.0.0.0/0`** for SSH (22), ICMP, HTTP (80), and HTTPS (443)
  (`terraform/modules/network/main.tf`). Fine for a research/demo project, not production-grade.
- **`k8s-manifests/ingress.yaml`** uses the deprecated `kubernetes.io/ingress.class` annotation
  instead of the newer `spec.ingressClassName` — still functional, just deprecated by
  Kubernetes/GKE.
- **`terraform.yaml` secrets use different names than `ci.yaml`/`cd.yaml`** for the same values
  (`PROJECT_ID` vs `GCP_PROJECT_ID`, `REGION` vs `GAR_REGION`, `ZONE` vs `GKE_ZONE`) — both sets
  must be kept in sync manually if you ever change project/region/zone.
- **`demo-application/requirements.txt` is UTF-16 encoded** — this did not cause any build
  failure in practice (`pip install` handled it fine), but it's unusual and worth knowing about
  if you ever edit that file with a tool that doesn't preserve encoding.
- **Postgres credentials are plaintext in git** (`k8s-manifests/secrets.yaml`,
  `helm-charts/deployments/values.yaml`) — pre-existing in the original repo.

---

## 17. Cost awareness / teardown

Running infrastructure incurs real GCP cost — roughly:
- 2× `e2-standard-4` compute: ~$195-200/month if left running continuously.
- GKE cluster management fee: typically waived for the first zonal cluster per billing account.
- Artifact Registry storage, GCS bucket, static IP: negligible (cents/month).

To tear down everything Terraform created (irreversible — only do this when you're done
experimenting):
```bash
cd terraform
terraform destroy
```
This does **not** remove the Artifact Registry repo, GCS state bucket, static IP, or WIF/IAM
resources created manually in §3-4 — those need to be deleted separately with `gcloud` if you
want a full cleanup:
```bash
gcloud compute addresses delete k8s-test --global --project=research-502304
gcloud artifacts repositories delete canary-repo --location=us-central1 --project=research-502304
gsutil rm -r gs://research-502304-tfstate
gcloud iam service-accounts delete gh-actions-deployer@research-502304.iam.gserviceaccount.com --project=research-502304
gcloud iam workload-identity-pools providers delete github-provider --workload-identity-pool=github-pool --location=global --project=research-502304
gcloud iam workload-identity-pools delete github-pool --location=global --project=research-502304
```

---

## 18. Quick-reference command index

| Task | Command |
|---|---|
| Connect kubectl | `gcloud container clusters get-credentials research-gke --zone us-central1-a --project research-502304` |
| Trigger CI build | `gh workflow run ci.yaml --repo tharinduk001/research` |
| Trigger canary deploy | `gh workflow run cd.yaml --repo tharinduk001/research -f image_tag=<N> -f namespace=dev` |
| Watch a workflow run | `gh run watch <run-id> --repo tharinduk001/research --exit-status` |
| List recent runs | `gh run list --repo tharinduk001/research --workflow=<ci\|cd>.yaml --limit 5` |
| Check pods | `kubectl get pods -n dev -l app=django -L track` |
| Check deployments | `kubectl get deployments -n dev` |
| Check ingress/cert | `kubectl get ingress -n dev` / `kubectl get managedcertificate -n dev` |
| Local test | `docker compose up --build -d` then `curl localhost:8000/health/` |
| Open Grafana (logs) | `kubectl port-forward svc/loki-grafana -n monitoring 3000:80` then browse `localhost:3000` |
| Get Grafana admin password | `kubectl get secret loki-grafana -n monitoring -o jsonpath='{.data.admin-password}' \| base64 -d` |

---

## 19. Observability — logs via Loki + Promtail + Grafana

Added after the pipeline was already fully working, as **Phase 1** of observability
(logs first; metrics/Prometheus deliberately deferred — see §19.7). This is a pure
workload addition: it does **not** touch Terraform, GKE cluster sizing, or the app's
CI/CD — it's just a new Helm release running alongside the app.

### 19.1 Why this approach

- **Helm**, not raw manifests or Terraform, because a Helm chart already exists in this
  repo (`helm-charts/deployments/`) establishing Helm as an already-used tool, and
  Grafana Labs ships an official chart that bundles everything needed (Loki + Promtail
  + Grafana) in one release.
- **Promtail** (not Filebeat/Fluent Bit/Logstash) as the log-shipping agent, because the
  chosen chart wires it up by default with zero extra config — it runs as a DaemonSet,
  one pod per node, and tails every container's stdout/stderr directly off the node
  filesystem. No code or app changes needed to get logs flowing.
- **Ephemeral storage** (no PersistentVolumeClaim) for Loki, deliberately — this is a
  first pass at "can we view app logs," not a long-term retention system. Logs are
  lost if the `loki-0` pod restarts. Revisit with `loki.persistence.enabled: true` if
  retention starts to matter.
- **`kubectl port-forward`** (not a public Ingress) to reach Grafana — avoids
  provisioning a new DNS record/ManagedCertificate for a UI that's only needed
  on-demand while investigating something.

### 19.2 Capacity check before installing anything

Before adding any new workload, the existing 2-node cluster's headroom was checked —
important because this project already hit a CPU-starvation issue once (§9.3), so
resource requests were sized conservatively rather than left at chart defaults:

```bash
kubectl describe nodes | grep -A5 "Allocatable:"
kubectl describe nodes | grep -B2 -A15 "Allocated resources:"
kubectl top nodes
```

At the time of installing this stack, both `e2-standard-4` nodes had **~2.7-2.9 CPU
cores and ~12Gi memory free** each (only ~25-30% of CPU requested by the existing app
+ GKE system pods) — comfortably enough for Loki/Promtail/Grafana without any node
resize.

### 19.3 Add the Helm repo

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana
```

### 19.4 Values file (checked into the repo)

Created `helm-charts/monitoring/loki-stack-values.yaml` — sets explicit conservative
resource requests/limits (so this new stack has a known, bounded footprint on the
2-node cluster), enables Grafana with the Loki datasource auto-provisioned via the
chart's sidecar, and explicitly disables the parts of this multi-tool chart that
aren't needed for Phase 1 (`prometheus`, `fluent-bit`, `filebeat`, `logstash`):

```yaml
# helm-charts/monitoring/loki-stack-values.yaml

loki:
  enabled: true
  isDefault: true
  persistence:
    enabled: false
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

promtail:
  enabled: true
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 150m
      memory: 128Mi

grafana:
  enabled: true
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 250m
      memory: 256Mi
  sidecar:
    datasources:
      enabled: true

prometheus:
  enabled: false
fluent-bit:
  enabled: false
filebeat:
  enabled: false
logstash:
  enabled: false
```

### 19.5 Install

```bash
helm install loki grafana/loki-stack -n monitoring --create-namespace \
  -f helm-charts/monitoring/loki-stack-values.yaml
```

> **Note:** Helm prints `WARNING: This chart is deprecated` on install. It still works
> fully — Grafana Labs' long-term recommendation is the separate `loki` + `grafana`
> charts with an agent like Alloy instead of this all-in-one chart, but for a
> logs-only Phase 1 this deprecated umbrella chart is the fastest correct path. Worth
> migrating off if this project's observability needs grow significantly.

Wait for everything to come up:
```bash
kubectl wait --for=condition=Ready pod -l app=loki -n monitoring --timeout=90s
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=90s
kubectl get pods -n monitoring
```
Expected result: `loki-0` (1/1), `loki-grafana-<hash>` (2/2), and one `loki-promtail-<hash>`
pod per node (2/2 total on a 2-node cluster), all `Running`.

Confirms no PVC was created (ephemeral storage, as intended):
```bash
kubectl get pvc -n monitoring   # -> "No resources found in monitoring namespace."
```

### 19.6 Access Grafana and view logs

Get the auto-generated admin password (username is always `admin`):
```bash
kubectl get secret loki-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
```

Port-forward Grafana to your machine:
```bash
kubectl port-forward svc/loki-grafana -n monitoring 3000:80
```

Open `http://localhost:3000`, log in with `admin` / `<password from above>` (change it
under user settings). Go to **Explore** → select the **Loki** datasource (already
pre-wired by the chart's sidecar, no manual setup) → run a LogQL query:

```logql
{namespace="dev"}                                # every pod in the dev namespace
{namespace="dev", pod=~"django-canary.*"}        # canary pods only (useful mid-rollout)
{namespace="dev", pod=~"django-stable.*"}        # stable pods only
```

### 19.7 What was deliberately deferred

- **Prometheus / metrics** — not installed yet. GKE already runs Google's Managed
  Service for Prometheus by default (`gmp-system` namespace: `gmp-operator` +
  `collector` pods, near-zero footprint), which may cover metrics needs without
  self-hosting `kube-prometheus-stack` at all. Decision deferred until metrics are
  actually needed.
- **Persistent log storage** — see §19.1; revisit if log history needs to survive
  pod restarts.
- **Public Grafana URL** — port-forward only for now; would need a new DNS record +
  `ManagedCertificate` (same pattern as §3/§9's app Ingress) if a permanent URL
  becomes worth the setup time.

### 19.8 Teardown (if needed)

```bash
helm uninstall loki -n monitoring
kubectl delete namespace monitoring
```
