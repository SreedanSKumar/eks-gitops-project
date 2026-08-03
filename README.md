# EKS + GitOps + Observability + Progressive Delivery

A complete platform engineering stack on AWS: a Terraform-provisioned EKS
cluster running Ubuntu worker nodes, ArgoCD-driven GitOps deployment to
staging and production, Prometheus + Grafana for metrics, Loki for
centralized logs, and Argo Rollouts for Canary / Blue-Green progressive
delivery.

```
Git commit
   │
   ▼
ArgoCD  ──sync──▶  EKS cluster (staging → prod, prod gated manually)
   │
   ├── kube-prometheus-stack (Prometheus + Grafana)
   ├── loki-stack (Loki + Promtail)
   └── Argo Rollouts (Canary / Blue-Green on the app itself)
```

---

## Contents

- [Architecture](#architecture)
- [File structure](#file-structure)
- [Prerequisites](#prerequisites)
- [Setup — step by step](#setup--step-by-step)
- [Verifying each component](#verifying-each-component)
- [Progressive delivery walkthrough](#progressive-delivery-walkthrough)
- [Troubleshooting](#troubleshooting)
- [Design decisions & known limitations](#design-decisions--known-limitations)

---

## Architecture

| Layer | Tool | What it does here |
|---|---|---|
| Infrastructure | Terraform + `terraform-aws-modules/eks` | Provisions the VPC (public/private subnets across 2 AZs, NAT gateway) and the EKS cluster + managed node group |
| Compute | Amazon EKS on Ubuntu 24.04 | Worker nodes run Canonical's official EKS-optimized Ubuntu AMI, looked up dynamically via SSM rather than hardcoded |
| Delivery | ArgoCD | Watches a Git repo and syncs Kubernetes manifests into the cluster. Staging auto-syncs; production requires an explicit manual sync (a deliberate promotion gate) |
| App config | Kustomize | One base Deployment/Service, patched per environment via `overlays/staging` and `overlays/prod` |
| Metrics | kube-prometheus-stack (Prometheus, Alertmanager, Grafana) | Deployed as an ArgoCD Application, not installed ad hoc — the monitoring stack itself is under GitOps |
| Logs | loki-stack (Loki + Promtail) | Also ArgoCD-managed; Promtail ships every pod's logs, queryable in Grafana |
| Progressive delivery | Argo Rollouts | Replaces the app's plain Deployment with a Rollout resource, supporting both Canary (weighted traffic steps) and Blue/Green (full cutover with manual promotion) strategies |
| Demo workload | [`argoproj/rollouts-demo`](https://github.com/argoproj/rollouts-demo) | The official Argo Rollouts demo image — renders its running version as a color, so traffic-shifting is visually observable during a live rollout |

---

## File structure

```
eks-gitops-project/
├── terraform/
│   ├── main.tf                     # VPC + EKS cluster + Ubuntu node group
│   ├── variables.tf                # All configurable inputs, with defaults
│   ├── outputs.tf                  # cluster endpoint, kubeconfig command, etc.
│   └── terraform.tfvars.example    # copy to terraform.tfvars and edit
├── k8s/
│   ├── base/                       # Base Deployment + Service (Kustomize)
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── staging/kustomization.yaml   # 1 replica, :yellow tag
│       └── prod/kustomization.yaml      # 5 replicas, :blue tag
├── argocd/apps/                    # ArgoCD Application CRDs
│   ├── app-staging.yaml            # auto-sync + self-heal
│   ├── app-prod.yaml               # manual sync only (promotion gate)
│   ├── app-monitoring.yaml         # kube-prometheus-stack via Helm
│   └── app-loki.yaml               # loki-stack via Helm
├── rollouts/
│   ├── rollout-canary.yaml         # weighted traffic-shift strategy
│   ├── rollout-bluegreen.yaml      # full-cutover strategy, manual promote
│   └── analysis-template.yaml      # reference-only Prometheus analysis gate
├── bootstrap.sh                    # scripted happy path through steps 1–4 below
└── README.md                       # this file
```

---

## Prerequisites

| Tool | Purpose | Install |
|---|---|---|
| Terraform ≥ 1.5 | Provisions AWS infrastructure | https://developer.hashicorp.com/terraform/install |
| AWS CLI, configured | Talks to your AWS account | `aws configure` |
| kubectl | Talks to the cluster | https://kubernetes.io/docs/tasks/tools/ |
| argocd CLI | Registers repos, syncs apps | `brew install argocd` or see [Argo CD releases](https://github.com/argoproj/argo-cd/releases) |
| kubectl argo rollouts plugin | Watches/promotes rollouts | `brew install argoproj/tap/kubectl-argo-rollouts` |
| A Git repo you control | Holds this project's manifests | push this whole folder to your own repo first |

Your AWS credentials need permission to create VPCs, EKS clusters/node
groups, IAM roles, KMS keys, and CloudWatch log groups.

---

## Setup — step by step

### 1. Configure

Copy the example vars file and edit it:
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Check these two values are still current before applying — both are
things AWS/Canonical update over time, and stale values are the most
common source of a failed `apply` (see [Troubleshooting](#troubleshooting)):

- `kubernetes_version` — check https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html for what's currently supported.
- `ubuntu_release` — worker nodes run Ubuntu via Canonical's official EKS-optimized AMI, looked up dynamically at apply time (no AMI ID to hardcode). Canonical occasionally lags a few days behind a brand-new EKS version — if `apply` fails on the AMI lookup, drop `kubernetes_version` one minor version and retry.

Then, in every file under `argocd/apps/`, replace the placeholder repo URL:
```yaml
repoURL: https://github.com/yourorg/yourrepo.git
```
with the URL of **your own repo** containing this project — not
`argoproj/rollouts-demo`, which is only the container image being
deployed, not the manifests repo.

### 2. Provision the cluster

```bash
terraform init
terraform apply
```
This takes **15–20 minutes** — most of it is AWS provisioning the EKS
control plane itself, which Terraform can only wait on, not speed up.
Track progress in a second terminal with:
```bash
aws eks describe-cluster --name <cluster-name> --region <region> --query "cluster.status"
```
`CREATING` → `ACTIVE` is normal and expected.

Once it finishes:
```bash
aws eks update-kubeconfig --name <cluster-name> --region <region>
kubectl get nodes
```
You should see your node(s) in `Ready` state, running Ubuntu.

### 3. Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
```
Get the initial admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```
Log in and register your Git repo:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
argocd login localhost:8080
argocd repo add <your-repo-url> --username <user> --password <token>
```

### 4. Deploy the app — staging first, then prod

```bash
kubectl apply -f argocd/apps/app-staging.yaml
```
This auto-syncs immediately. Once you've confirmed staging looks correct:
```bash
kubectl apply -f argocd/apps/app-prod.yaml
argocd app sync demo-app-prod
```
`app-prod.yaml` deliberately has no `syncPolicy.automated` block — this
manual step is the promotion gate, not a bug.

### 5. Bring up observability (also GitOps-managed)

```bash
kubectl apply -f argocd/apps/app-monitoring.yaml
kubectl apply -f argocd/apps/app-loki.yaml
```
Access Grafana:
```bash
kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80
```
Default login is `admin` / the password set in `app-monitoring.yaml`'s
Helm values — **change this before treating the cluster as anything more
than a lab environment.**

### 6. Install Argo Rollouts and cut over to progressive delivery

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl apply -f rollouts/rollout-canary.yaml     # or rollout-bluegreen.yaml
```

Or run `./bootstrap.sh` to script steps 2–4 in one go — read it first; it
deliberately stops short of registering your Git repo or syncing prod,
since those need your judgment/credentials.

---

## Verifying each component

Use this as a checklist once everything's deployed — this is what
"working" actually looks like, and what to check if something seems off.

**Terraform / EKS**
```bash
terraform state list          # should list vpc, eks cluster, node group resources
kubectl get nodes             # nodes Ready, VERSION matches your kubernetes_version
```

**ArgoCD**
```bash
argocd app list
```
Staging should show `Synced` / `Healthy`. Prod should show `OutOfSync`
until you manually sync it — that's correct, not broken.

**Prometheus**
```bash
kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090
```
Open `localhost:9090/targets` — every target should read `UP`, with a
"last scrape" time that's continuously recent on refresh.

**Grafana**
```bash
kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80
```
Open the bundled **Kubernetes / Compute Resources / Cluster** dashboard —
panels should show real moving lines, not "No data". Under **Connections
→ Data sources**, both Prometheus and Loki should pass "Test".

**Loki**
In Grafana → **Explore** → select the Loki data source → run:
```
{namespace="staging"}
```
You should get back live, timestamped log lines from your actual pods.

**Argo Rollouts**
```bash
kubectl argo rollouts get rollout demo-app --watch
```
Should show the rollout's current strategy, step, and per-ReplicaSet pod
health — covered in detail below.

---

## Progressive delivery walkthrough

The deployed app uses [`argoproj/rollouts-demo`](https://github.com/argoproj/rollouts-demo)
— tags are colors (`red`, `orange`, `yellow`, `green`, `blue`, `purple`),
plus `bad-<color>` and `slow-<color>` variants for demoing a failed or
slow rollout. No Dockerfile or registry needed, it's already public.

**Trigger a canary rollout:**
```bash
kubectl argo rollouts set image demo-app demo-app=argoproj/rollouts-demo:yellow
kubectl argo rollouts get rollout demo-app --watch
```
Watch `SetWeight` / `ActualWeight` climb through the configured steps
(20 → 40 → 60 → 80 → 100 in `rollout-canary.yaml`), pausing between each.

**Demo a bad rollout / rollback:**
```bash
kubectl argo rollouts set image demo-app demo-app=argoproj/rollouts-demo:bad-yellow
kubectl argo rollouts abort demo-app
```

**Blue/Green instead:**
```bash
kubectl apply -f rollouts/rollout-bluegreen.yaml
kubectl argo rollouts set image demo-app demo-app=argoproj/rollouts-demo:green
kubectl port-forward svc/demo-app-preview 8081:80   # inspect before cutover
kubectl argo rollouts promote demo-app              # cut traffic over
```

**Live dashboard, good for demos:**
```bash
kubectl argo rollouts dashboard
# open http://localhost:3100
```

`rollouts/analysis-template.yaml` is included as a **reference only** —
it's not wired into either rollout by default, because `rollouts-demo`
doesn't emit the Prometheus metrics (`http_requests_total`) it queries
for. Wire it in once you're deploying a real, instrumented application.

---

## Troubleshooting

Every one of these is a real error hit while building this project, not
a hypothetical.

### `InvalidParameterException: unsupported Kubernetes version`
AWS retires old EKS versions on a rolling cycle. Check current supported
versions at https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html
and bump `kubernetes_version` in `terraform.tfvars`, then re-apply.
**Never** fix this by changing the version in the AWS console — Terraform's
state won't know about it and will fight the change on the next apply.
Always edit `.tfvars` and re-run `terraform apply`.

### `InvalidParameterException: AMI Type AL2_x86_64 is only supported for kubernetes versions 1.32 or earlier`
AWS retired the Amazon Linux 2 AMI type for EKS on Kubernetes 1.33+. This
project's node group runs Ubuntu via a custom AMI (`ami_type = "CUSTOM"`),
so this specific error shouldn't recur here — documented in case you ever
switch back to an AWS-provided AMI type, which on 1.33+ needs to be
`AL2023_x86_64_STANDARD` (or Bottlerocket), not `AL2_x86_64`.

### `ParameterNotFound` on `data.aws_ssm_parameter.ubuntu_eks_ami`
Canonical publishes a matching Ubuntu EKS AMI per Kubernetes minor
version, but can lag a few days behind a brand-new EKS release. Either
wait and retry, or drop `kubernetes_version` to the previous minor
version (still well within support) and re-apply.

### `VpcLimitExceeded: The maximum number of VPCs has been reached`
Default AWS quota is 5 VPCs/region. Usually means earlier failed `apply`
attempts left orphaned VPCs behind (local Terraform state didn't track
them, so it tried creating new ones instead of reusing them).

1. Find the orphan:
   ```bash
   aws ec2 describe-vpcs --region <region> --query "Vpcs[].{ID:VpcId,CIDR:CidrBlock,Default:IsDefault,Name:Tags[?Key=='Name']|[0].Value}" --output table
   ```
2. Delete any NAT Gateway on it first (blocks VPC deletion, holds an
   Elastic IP):
   ```bash
   aws ec2 describe-nat-gateways --region <region> --filter "Name=vpc-id,Values=<vpc-id>" --query "NatGateways[].NatGatewayId" --output table
   aws ec2 delete-nat-gateway --nat-gateway-id <nat-gw-id> --region <region>
   ```
   Wait ~60s after deletion before deleting the VPC.
3. Delete the VPC via the **AWS Console** (VPC → Your VPCs → Actions →
   Delete VPC) — it cascades through subnets/route tables/IGW for you.
4. Clean up the KMS alias and CloudWatch log group left behind from the
   same failed apply (these throw "already exists" otherwise):
   ```bash
   aws kms delete-alias --alias-name alias/eks/<cluster-name> --region <region>
   aws logs delete-log-group --log-group-name /aws/eks/<cluster-name>/cluster --region <region>
   ```

**Root cause / prevention:** this project uses local Terraform state (a
`terraform.tfstate` file on disk, no backend). If that file is deleted,
or `apply` is re-run from a different machine/directory, Terraform loses
track of what it already created and tries to recreate everything — hence
orphans. Never delete `terraform.tfstate` between attempts, always
apply/destroy from the same directory. For anything beyond a quick lab,
add an S3 backend so state survives local resets.

### Unexpected number of EC2 instances running
Check the Auto Scaling Group backing the node group first — it relaunches
anything you terminate manually unless zeroed out:
```bash
aws autoscaling describe-auto-scaling-groups --region <region> --query "AutoScalingGroups[].{Name:AutoScalingGroupName,Desired:DesiredCapacity,Min:MinSize,Max:MaxSize}" --output table
aws autoscaling update-auto-scaling-group --auto-scaling-group-name <name> --min-size 0 --desired-capacity 0 --max-size 0 --region <region>
```
Then confirm nothing's left:
```bash
aws ec2 describe-instances --region <region> --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name}" --output table
```
If the count matches your `node_desired_size`, that's expected (tail end
of node group provisioning), not a leak. If it's much larger, in a region
or instance type you didn't configure, treat it as a possible credential
leak — rotate the AWS access key immediately and check CloudTrail.

---

## Design decisions & known limitations

- **Prod is not auto-synced, on purpose.** `app-prod.yaml` has no
  `syncPolicy.automated` block, requiring an explicit `argocd app sync`
  after staging is validated.
- **`rollouts-demo` is a demo app, not a real service.** It's ideal for
  visually showing canary/blue-green mechanics, but doesn't expose real
  business metrics — hence `analysis-template.yaml` being reference-only.
- **Change the Grafana admin password** in `app-monitoring.yaml` before
  using this beyond a lab — it's currently a plaintext placeholder in
  Helm values. Better: reference a Kubernetes Secret instead.
- **`loki-stack` is deprecated upstream** in favor of the split `loki` +
  `alloy`/`loki-canary` charts, but remains the fastest path to "logs in
  Grafana" for a lab setup. Swap it for the newer charts before using
  this in production.
- **Local Terraform state, no backend.** Fine for solo/lab use; add an S3
  backend (with DynamoDB locking) before multiple people or machines
  touch this, or before it holds anything you can't afford to lose track
  of (see the VPC-limit troubleshooting entry above for what goes wrong
  otherwise).
