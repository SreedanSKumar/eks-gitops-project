#!/usr/bin/env bash
# Bootstraps the full stack in order. Run section by section rather
# than blindly executing top-to-bottom — review each step's output
# before moving to the next, especially the Terraform apply.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-demo-cluster}"
AWS_REGION="${AWS_REGION:-us-east-1}"
GIT_REPO="${GIT_REPO:-https://github.com/yourorg/yourrepo.git}"

echo "== 1. Terraform: provision EKS =="
cd terraform
terraform init
terraform apply -auto-approve
cd ..

echo "== 2. Configure kubectl =="
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl get nodes

echo "== 3. Install ArgoCD =="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo "ArgoCD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""
echo "Run 'kubectl port-forward svc/argocd-server -n argocd 8080:443' in another shell, then 'argocd login localhost:8080'"

echo "== 4. Install Argo Rollouts controller + kubectl plugin (controller only shown here) =="
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

echo "== 5. Register your Git repo with ArgoCD (edit credentials as needed) =="
echo "  argocd repo add $GIT_REPO --username <user> --password <token-or-app-password>"

echo "== 6. Apply ArgoCD Applications (staging, prod, monitoring, loki) =="
kubectl apply -f argocd/apps/app-staging.yaml
kubectl apply -f argocd/apps/app-monitoring.yaml
kubectl apply -f argocd/apps/app-loki.yaml
echo "NOTE: app-prod.yaml is intentionally NOT auto-applied here."
echo "Apply it manually once staging is validated:"
echo "  kubectl apply -f argocd/apps/app-prod.yaml"

echo "== Done. Next steps are manual: validate staging, apply prod app, then try a rollout. =="
