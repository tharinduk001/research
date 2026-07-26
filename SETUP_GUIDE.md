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
| Monitoring namespace | `default` (Prometheus/Grafana/Alertmanager/Loki/Promtail) |
| Monitoring Helm releases | `prometheus` (kube-prometheus-stack), `loki`, `promtail` |
| Monitoring source repo | `github.com/tharinduk001/Monitoring-Stack-Workflow` (workflow file adapted into this repo) |

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
| Trigger monitoring stack deploy | `gh workflow run automate.yaml --repo tharinduk001/research -f namespace=default -f install_prometheus_grafana=true -f install_loki=true -f install_promtail=true` |
| Open Grafana | `kubectl port-forward svc/prometheus-grafana -n default 8081:80` then browse `localhost:8081` |
| Get Grafana admin password | `kubectl get secret prometheus-grafana -n default -o jsonpath='{.data.admin-password}' \| base64 -d` |
| Open Prometheus | `kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n default 9090:9090` then browse `localhost:9090` |
| Open Alertmanager | `kubectl port-forward svc/prometheus-kube-prometheus-alertmanager -n default 9093:9093` then browse `localhost:9093` |
| Check track split is working | `curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=count by (track) (up{job=~"django.*"})'` |
| Check DB exporter connected | `curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=pg_up'` (1 = connected) |

---

## 19. Observability — Prometheus + Grafana + Alertmanager + Loki + Promtail

Full monitoring stack, adapted from a separate reference repo the team lead shared:
`github.com/tharinduk001/Monitoring-Stack-Workflow`. Unlike an earlier logs-only
attempt (Loki+Grafana via the deprecated `loki-stack` chart, since fully removed),
this uses the correct current charts and also wires up **application-level metrics**
(not just cluster/node metrics) via a custom Prometheus `ServiceMonitor`.

### 19.1 What actually gets installed

A single GitHub Actions workflow (`workflow_dispatch`) installs three separate Helm
releases into one namespace:
- **`prometheus-community/kube-prometheus-stack`** — an umbrella chart bundling the
  Prometheus Operator, Prometheus itself, Alertmanager, Grafana, kube-state-metrics,
  and node-exporter. Installing it also registers new Kubernetes CRDs (`Prometheus`,
  `ServiceMonitor`, `Alertmanager`, `PrometheusRule`) and ships a large bundle of
  pre-built dashboards (from the `kubernetes-mixin` project) as labeled ConfigMaps
  that a sidecar container in the Grafana pod auto-imports on startup — this is why
  working dashboards and a pre-wired Prometheus datasource appear with **zero**
  custom Grafana configuration.
- **`grafana/loki`** — modern standalone Loki chart (SingleBinary mode, filesystem
  storage, no persistence). Ships with no dashboards and does not auto-register
  itself as a Grafana datasource — that has to be done manually (§19.7).
- **`grafana/promtail`** — DaemonSet, one pod per node, tails container logs and
  pushes them to Loki. Stateless, no UI of its own.

### 19.2 Why WIF didn't need any changes

The workflow authenticates via the same Workload Identity Federation setup as every
other workflow in this repo (§4) — because it runs *inside* `tharinduk001/research`,
it automatically satisfies the existing `attribute-condition` (which trusts exactly
this repo), so no new WIF pool/provider/IAM binding was needed. (A Service Account
key was considered and explicitly rejected — see project decision log.)

### 19.3 Files brought in from the reference repo

Only 2 files were actually needed — everything else in that repo (a whole separate
demo Django app, manual notes duplicating the workflow's own Helm commands, WIF setup
notes for a different GCP project) was not applicable here:

**`.github/workflows/automate.yaml`** — copied in unmodified. `workflow_dispatch`
inputs: `namespace` (choice: prod/staging/dev/qa/default), and 3 booleans to
independently toggle installing Prometheus+Grafana / Loki / Promtail.

**`k8s-manifests/svc-monitor.yaml`** — brought in, then **rewritten** (see §19.4). The
reference repo's version scraped a single Service, which cannot tell stable pods from
canary pods — a hard requirement for this project (§19.4).

### 19.4 Separating stable from canary metrics (per-track Services)

**The problem.** The reference repo's `ServiceMonitor` scraped one Service
(`django-svc`), which selects `app: django` — i.e. **both** tracks at once. Metrics
came back tagged only with `pod`, `job`, `namespace`, `container`, `service`. Pod
*labels* (`track: stable` / `track: canary`, which the Deployments do set) are **not**
carried onto metrics automatically. So there was no clean way to ask "how is canary
behaving compared to stable?" — only fragile pod-name regexes.

This matters because the research goal (predicting rollout failure) depends on
comparing the canary against the stable baseline running at the same moment.

**The fix — two monitoring-only Services, one per track.** These carry no user
traffic; `django-svc` still serves that, and the Ingress references it by name.
These exist purely so Prometheus sees each track as its own group.

`k8s-manifests/track-svc.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: django-stable-svc
  namespace: dev
  labels:
    monitoring: django     # what the ServiceMonitor selects on
    track: stable          # copied onto metrics via targetLabels
spec:
  type: ClusterIP
  selector:
    app: django
    track: stable          # only stable pods land in this Service's Endpoints
  ports:
    - name: web
      port: 8000
      targetPort: 8000
---
# django-canary-svc — identical, with track: canary in both labels and selector
```

`k8s-manifests/svc-monitor.yaml` (rewritten):
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: django-servicemonitor
  namespace: dev
  labels:
    release: prometheus      # must match the Prometheus Helm release name
spec:
  selector:
    matchLabels:
      monitoring: django     # matches BOTH track Services
  targetLabels:
    - track                  # copies each Service's `track` label onto its metrics
  endpoints:
    - port: web
      path: /metrics
      interval: 15s
```

**Why `targetLabels` is the key line.** It copies a *Service's* own labels onto every
metric scraped through that Service. Because `django-stable-svc` is labelled
`track: stable`, everything scraped through it arrives tagged `track="stable"`. That
turns track comparison into ordinary PromQL:
```promql
rate(django_http_responses_total_by_status_total{track="canary"}[1m])
```
(The alternative — `relabelings` with `__meta_kubernetes_pod_label_track` — reads pod
labels directly and needs no extra Services, but the per-Service approach above was
chosen as the clearer model to reason about.)

**Avoiding double-scraping.** The `ServiceMonitor` deliberately selects on
`monitoring: django`, a label only the two new Services carry. `django-svc` keeps its
`app: django` label and is therefore **not** scraped — otherwise every pod would be
scraped twice (once per Service) and produce duplicate series.

Apply (no downtime — nothing about traffic routing changes):
```bash
kubectl apply -f k8s-manifests/track-svc.yaml
kubectl apply -f k8s-manifests/svc-monitor.yaml
```

Verify — expect exactly one scrape pool, and a `track` label on the metrics:
```bash
kubectl get endpoints -n dev     # django-stable-svc has pods; django-canary-svc is
                                 # empty between releases (canary sits at 0 replicas)

curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=count by (track) (up{job=~"django.*"})'
```

> **Note on `django-svc`:** its `app: django` label and named port `web` (added
> earlier, when it was still the scrape target) are now unused by monitoring. They are
> harmless and were left in place.

> **Known drift:** `helm-charts/deployments/templates/` has not been updated with the
> track Services or the ServiceMonitor. The raw manifests in `k8s-manifests/` are the
> deployment path actually used by this project (§11); the Helm chart is an unused
> alternative and was already out of sync before this change.

### 19.5 GitHub secrets

The workflow expects different secret **names** than our existing ones for the same
values (naming-convention mismatch, same pattern as the `terraform.yaml` vs
`ci.yaml`/`cd.yaml` quirk in §7) — `GCP_PROJECT_ID` and `GKE_CLUSTER_NAME` already
existed and needed no change; 2 new ones were required:
```bash
REPO="tharinduk001/research"
gh secret set GCP_REGION --repo "$REPO" --body "us-central1"
gh secret set GKE_CLUSTER_LOCATION --repo "$REPO" --body "us-central1-a"
```

### 19.6 Instrument the Django app for `/metrics`

Without this, Prometheus has a target to scrape but nothing to scrape *from* — the
app itself must expose metrics.

```bash
pip install django-prometheus   # added to demo-application/requirements.txt
```

**`demo-application/simply/settings.py`**:
```python
INSTALLED_APPS = [
    ...
    'home.apps.HomeConfig',
    'django_prometheus',
]

MIDDLEWARE = [
    'django_prometheus.middleware.PrometheusBeforeMiddleware',   # must be first
    'django.middleware.security.SecurityMiddleware',
    ...
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
    'django_prometheus.middleware.PrometheusAfterMiddleware',    # must be last
]

# Instruments queries from the Django app's side. Drop-in replacement for
# 'django.db.backends.postgresql' — same behaviour, plus metrics. Without this
# the django_db_* metrics do not exist at all.
DATABASES = {
    'default': {
        'ENGINE': 'django_prometheus.db.backends.postgresql',
        ...
    }
}
```

**`demo-application/simply/urls.py`**:
```python
urlpatterns = [
    path('admin/', admin.site.urls),
    path('', include('home.urls')),
    path('', include('django_prometheus.urls')),   # exposes /metrics
]
```

> **Encoding gotcha hit during this step:** `demo-application/requirements.txt` was
> already UTF-16 encoded (a pre-existing quirk, §16). Rewriting it while adding the
> new dependency produced UTF-16 **without a byte-order mark**, which broke `pip`
> entirely (`ERROR: Invalid requirement: 'a\x00s\x00g\x00i\x00r\x00e\x00f\x00...'`) —
> the original file's BOM was apparently what let earlier builds succeed; without one,
> pip reads raw null-interleaved bytes. Fixed by recreating the file as plain
> ASCII/UTF-8 (`file requirements.txt` should report `ASCII text`, not `data`). If
> editing this file again, verify its encoding before pushing:
> ```bash
> file demo-application/requirements.txt   # must say "ASCII text", not "data"
> ```

### 19.7 Commit, push, deploy the monitoring stack

```bash
git add .github/workflows/automate.yaml k8s-manifests/svc-monitor.yaml \
        k8s-manifests/track-svc.yaml k8s-manifests/app-svc.yaml
git commit -m "Add Prometheus+Grafana+Loki+Promtail monitoring pipeline"
git push origin main

gh workflow run automate.yaml --repo tharinduk001/research \
  -f namespace=default \
  -f install_prometheus_grafana=true \
  -f install_loki=true \
  -f install_promtail=true
gh run list --repo tharinduk001/research --workflow=automate.yaml --limit 1   # get run id
gh run watch <run-id> --repo tharinduk001/research --exit-status
```
Takes ~4 minutes. Installs into the `default` namespace: Prometheus, Grafana,
Alertmanager, kube-state-metrics, 2× node-exporter (one per node), Loki, 2× Promtail
(one per node).

### 19.8 Deploy the instrumented app itself

The `ServiceMonitor`/Service fixes only matter once the *running* app pods actually
have `django-prometheus` in them — that requires a normal release cycle (§14):
```bash
git add demo-application/requirements.txt demo-application/simply/settings.py demo-application/simply/urls.py
git commit -m "Instrument Django app with django-prometheus for /metrics endpoint"
git push origin main

gh workflow run ci.yaml --repo tharinduk001/research
gh run list --repo tharinduk001/research --workflow=ci.yaml --limit 1   # note run number = new image tag
gh run watch <run-id> --repo tharinduk001/research --exit-status

gh workflow run cd.yaml --repo tharinduk001/research -f image_tag=<N> -f namespace=dev
gh run list --repo tharinduk001/research --workflow=cd.yaml --limit 1
gh run watch <run-id> --repo tharinduk001/research --exit-status
```

Then apply the track Services and the `ServiceMonitor` (the ServiceMonitor is only
possible after §19.7 has run — its CRD doesn't exist until Prometheus Operator
installs it):
```bash
kubectl apply -f k8s-manifests/track-svc.yaml
kubectl apply -f k8s-manifests/svc-monitor.yaml
```

### 19.9 Verify metrics are actually flowing

```bash
# App exposes /metrics directly
kubectl port-forward svc/django-svc -n dev 8000:8000
curl -s http://localhost:8000/metrics | head -20

# Prometheus is scraping it (look for "health":"up" under serviceMonitor/dev/django-servicemonitor)
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n default 9090:9090
curl -s "http://localhost:9090/api/v1/targets" | grep -A1 "django-servicemonitor"
```

### 19.10 Access the dashboards

```bash
# Grafana
kubectl port-forward svc/prometheus-grafana -n default 8081:80
kubectl get secret prometheus-grafana -n default -o jsonpath='{.data.admin-password}' | base64 -d
# -> browse http://localhost:8081, login admin / <password above>

# Prometheus (no login)
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n default 9090:9090
# -> http://localhost:9090 — Status > Targets to check scrape health, Graph for PromQL

# Alertmanager (no login)
kubectl port-forward svc/prometheus-kube-prometheus-alertmanager -n default 9093:9093
# -> http://localhost:9093
```

> **Windows port gotcha:** ports `3000`/`3001` failed to bind locally
> (`bind: An attempt was made to access a socket in a way forbidden by its access
> permissions`) — a Windows-reserved/excluded port range (common with Docker
> Desktop/WSL/Hyper-V), not a real conflict. Used `8081` instead. If a local
> port-forward fails the same way, just pick a different local port — the remote
> side (`:80`, `:9090`, etc.) stays the same.

Grafana here comes with Prometheus **pre-wired as a datasource** and a set of
pre-built dashboards already imported (Kubernetes cluster overview, node metrics,
pod resources) — see §19.1 for why. Loki is **not** auto-wired by this chart and had
to be added manually:
```bash
curl -s -X POST http://admin:<grafana-password>@localhost:8081/api/datasources \
  -H "Content-Type: application/json" \
  -d '{"name":"Loki","type":"loki","url":"http://loki.default.svc.cluster.local:3100","access":"proxy","isDefault":false}'
```

### 19.11 Example queries once flowing

PromQL (Prometheus Graph tab or Grafana Explore → Prometheus datasource):
```promql
# scrape health, split by track
count by (track) (up{job=~"django.*"})

# request/error rates per track
sum by (track) (rate(django_http_requests_total_by_method_total[1m]))
sum by (track) (rate(django_http_responses_total_by_status_total{status=~"5.."}[1m]))

# canary vs stable latency comparison (the core research signal — during a rollout,
# when django-canary has running pods)
histogram_quantile(0.95,
  sum by (track, le) (rate(django_http_requests_latency_seconds_by_view_method_bucket[1m]))
)
```

LogQL (Grafana Explore → Loki datasource):
```logql
{namespace="dev", pod=~"django-stable.*"}
```

> **Note:** Promtail does **not** attach a `track` label to logs (it tags `app`,
> `pod`, `namespace`, `node_name`, `container`, `detected_level`). Until that is
> configured, separate tracks in logs by pod name: `pod=~"django-canary.*"`.

---

## 20. Database metrics (two independent sources)

Two complementary views, both needed — they fail differently and catch different
problems:

| Source | Vantage point | Catches |
|---|---|---|
| `django_prometheus` DB backend | what the **app** experiences | query errors, bad migrations, app-side latency |
| `postgres_exporter` | what the **server** is doing | connection exhaustion, locks, DB size growth |

### 20.1 App-side (django_prometheus)

Already covered in §19.6 — the `ENGINE` line. Once deployed it provides:
`django_db_execute_total`, `django_db_query_duration_seconds_*`,
`django_db_new_connections_total`.

Note these only appear **after** the app image containing the change is actually
rolled out (§19.8) — changing `settings.py` alone does nothing until a release ships.

### 20.2 Server-side (postgres_exporter)

`k8s-manifests/postgres-exporter.yaml` deploys the exporter, a Service, and its
ServiceMonitor. Credentials are read from the existing `postgres-secret`, so no
password is duplicated:

```yaml
env:
  # postgres-svc is headless, but DNS still resolves to the pod IP
  - name: DATA_SOURCE_URI
    value: "postgres-svc:5432/db?sslmode=disable"
  - name: DATA_SOURCE_USER
    valueFrom:
      secretKeyRef: { name: postgres-secret, key: POSTGRES_USER }
  - name: DATA_SOURCE_PASS
    valueFrom:
      secretKeyRef: { name: postgres-secret, key: POSTGRES_PASSWORD }
```

The Service is labelled `monitoring: postgres` and its ServiceMonitor selects that
label (same pattern as the track Services in §19.4).

Apply and verify:
```bash
kubectl apply -f k8s-manifests/postgres-exporter.yaml
kubectl rollout status deployment/postgres-exporter -n dev --timeout=120s

# pg_up must be 1 — the pod starting is NOT proof it connected to the database
kubectl logs -n dev deployment/postgres-exporter --tail=10   # look for "Established new database connection"
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=pg_up'
```

Provides: `pg_up`, `pg_stat_database_numbackends` (active connections),
`pg_locks_count`, `pg_database_size_bytes`, `pg_replication_lag_seconds`, plus the
full `pg_settings_*` set.

### 20.3 Example DB queries

```promql
# app-side: query rate and latency, split by track
sum by (track) (rate(django_db_execute_total[2m]))
histogram_quantile(0.95, sum by (track, le) (rate(django_db_query_duration_seconds_bucket[5m])))

# server-side: active connections, lock pressure
pg_stat_database_numbackends{datname="db"}
pg_locks_count
```

---

## 21. Load generator (k6)

Without it ~100% of traffic is health probes, so no user-facing code path is
exercised and a broken canary can look healthy. Required before any dataset work.

`k8s-manifests/load-generator.yaml` = ConfigMap (k6 script) + Deployment. Key design
choices, all deliberate:
- Targets the **in-cluster** Service, not the public HTTPS URL — external LB adds
  internet latency jitter that is not caused by the code change, i.e. noise in the
  canary-vs-stable comparison. Internal HTTP also sidesteps Django's CSRF referer check.
- `constant-arrival-rate` executor — the load itself must not vary, or that variance
  becomes a confounder.
- ~5% of iterations do a **failed POST login**. This is the only path that touches the
  database (`auth.authenticate()` queries the User table); GET views just render
  templates. Without it the `django_db_*` metrics stay at zero.
- No k6 thresholds — k6 must never abort. Errors during a bad canary are the signal
  being recorded, not a reason to stop generating load.

```bash
kubectl apply -f k8s-manifests/load-generator.yaml
kubectl rollout status deployment/loadgen -n dev --timeout=180s
```

Change the rate (takes effect immediately, restarts the pod):
```bash
kubectl set env deployment/loadgen -n dev RATE=25
```

Start / stop without deleting:
```bash
kubectl scale deployment loadgen -n dev --replicas=0    # stop
kubectl scale deployment loadgen -n dev --replicas=1    # start
```

### 21.1 App resource sizing (must be done before running load)

The original manifests requested 64Mi/125m and limited 128Mi/250m. That cannot
survive real traffic — the container runs 3 gunicorn workers × 6 threads, and each
worker needs 60-80Mi. Starting the load generator OOMKilled all 5 pods (exit 137).
Current values, already in the manifests:

```yaml
resources:
  requests: { memory: "256Mi", cpu: "300m" }
  limits:   { memory: "512Mi", cpu: "2000m" }
```

> **Do not `kubectl apply -f k8s-manifests/stable-deployment.yaml` to change
> resources on a live cluster** — that file hardcodes `canary-app:1` and applying it
> would roll the app back to the first image. Patch the live deployment instead:
> ```bash
> for d in django-stable django-canary; do
>   kubectl set resources deployment/$d -n dev \
>     --requests=memory=256Mi,cpu=300m --limits=memory=512Mi,cpu=2000m
> done
> ```

> **Why cpu limit is 2000m and not 1000m:** at 1000m, CPU throttling sat at 56% even
> though actual usage was only ~300m — 18 gunicorn threads exhaust the CFS quota in
> bursts. Throttling ratio is a fault signal for this project, so its baseline must be
> low (now ~1.7%) or a real CPU regression produces no visible rise.

### 21.2 Manual verification commands

Assumes `kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n default 9090:9090`
is running.

```bash
# --- pod health: all Running, restarts should stay at 0 ---
kubectl get pods -n dev
kubectl top pods -n dev -l track=stable

# --- OOMKill check (exit 137 = out of memory) ---
kubectl get pod -n dev -l track=stable -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'

# --- load generator health: look for "Request Failed", should be none ---
kubectl logs -n dev deployment/loadgen --tail=20
kubectl logs -n dev deployment/loadgen --since=60s | grep -c "Request Failed"

# --- traffic mix by view (user views should dominate, not ready/live) ---
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=topk(8, sum by (view) (rate(django_http_requests_total_by_view_transport_method_total[3m])))'

# --- total throughput and error rate ---
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=sum(rate(django_http_requests_total_by_method_total[3m]))'
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=sum(rate(django_http_responses_total_by_status_total{status=~"5.."}[3m])) or vector(0)'

# --- CPU throttling ratio: must stay low (~0.02), else the signal is saturated ---
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=avg(sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="dev",pod=~"django-stable.*"}[3m])) / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="dev",pod=~"django-stable.*"}[3m])))'

# --- latency PER VIEW (aggregate percentiles are misleading, see RESEARCH_STATUS 3.5) ---
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=histogram_quantile(0.95, sum by (view, le) (rate(django_http_requests_latency_seconds_by_view_method_bucket[3m])))'

# --- DB is actually being exercised (should be non-zero) ---
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=sum(rate(django_db_execute_total[3m]))'

# --- track split (during a rollout: stable + canary both present) ---
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode \
  'query=count by (track) (up{job=~"django.*"})'
```

### 21.3 Healthy baseline (2026-07-26, RATE=25, image tag 7)

Measured **after** the single-worker fix (§21.4) — earlier figures were corrupted and
must not be used. Reference values; if these drift substantially, something changed:

| Signal | Healthy value |
|---|---|
| total throughput | ~32 req/s |
| 5xx rate | 0 |
| DB queries | ~7/s |
| p50 latency (all views) | ~6 ms |
| p95 latency (all views) | ~42 ms |
| p99 latency (all views) | ~1.9 s — login POST only, see RESEARCH_STATUS §3.5 |
| p95 `login` | ~1.6 s (password hashing, expected) |
| p95 `home` / `register` | ~10 ms |
| CPU throttling | ~2% |
| memory per pod | ~62 Mi of 512 Mi |
| CPU per pod | 300-400m of 2000m |

### 21.4 Gunicorn must run a single worker (metrics correctness)

**Do not raise `--workers` above 1 without reading this.**

django-prometheus keeps its counters in process memory. With N gunicorn workers each
worker holds its own independent counters, and `/metrics` is served by whichever
worker answers the scrape. Prometheus therefore sees the counter jump up and down,
treats every drop as a counter reset, and adds the "lost" amount — inflating `rate()`
without bound as the workers diverge.

Observed with 3 workers: a single pod's counter alternated between ~56k / ~72k / ~89k,
and `sum(rate(...))` reported **9,500 req/s against an actual ~30 req/s** (~800x). The
error grows over time as workers drift apart, so a freshly-rolled deployment looks
only mildly wrong while a long-running one is catastrophically wrong.

Detect it:
```bash
# Counter MUST increase monotonically. Sawtoothing between distinct value bands
# means multiple workers are reporting independently.
P=$(kubectl get pods -n dev -l track=stable -o jsonpath='{.items[0].metadata.name}')
END=$(date +%s); START=$((END-180))
curl -s 'http://localhost:9090/api/v1/query_range' \
  --data-urlencode "query=django_http_requests_total_by_method_total{pod=\"$P\",method=\"GET\"}" \
  --data-urlencode "start=$START" --data-urlencode "end=$END" --data-urlencode 'step=20'
```

Also sanity-check throughput against what k6 is actually sending
(`kubectl logs -n dev deployment/loadgen | grep iters/s`) — a large mismatch is the
same symptom.

The alternative fix (`PROMETHEUS_MULTIPROC_DIR`) keeps multiple workers but drops
`process_*` and `python_gc_*` from the registry; those are wanted as leading-indicator
signals, so the single worker was preferred. Load is ~6 req/s per pod, so one worker
with 8 threads has ample headroom.

**Unaffected by this bug:** `container_*` (cAdvisor), `kube_*` (kube-state-metrics)
and `pg_*` (postgres_exporter) are scraped independently of gunicorn and were always
correct.
