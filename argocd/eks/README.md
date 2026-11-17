# EKS environment

ArgoCD runs **inside** the EKS cluster and manages it (`server: https://kubernetes.default.svc` is the EKS cluster). The homelab keeps its own ArgoCD and its own files under `argocd/apps`, `argocd/appsets`, `argocd/projects`: nothing there is used by EKS.

| Path | What |
|---|---|
| `bootstrap/platform-root-eks.yaml` | Root Application, syncs `apps/` (manual `kubectl apply`) |
| `projects/platform-infra.yaml` | AppProject for platform components (manual `kubectl apply`) |
| `projects/platform-apps.yaml` | AppProject for workloads, namespace `flights` (managed by the `projects` Application) |
| `apps/` | One Application per component (below) |
| `platform/storageclass`, `platform/ingress`, `mesh/` | Plain manifests that `apps/` point at |
| `../../charts/*/values-eks.yaml` | EKS values for the three charts (ECR images, tolerations, ESO, ...) |
| `../../infra/helm-values/argocd-eks.yaml` | EKS overlay for the ArgoCD chart |

Not deployed on EKS: the monitoring stack (Prometheus, Loki, Jaeger, Alloy). A t3.medium holds 17 pods and the credits are limited.

## Sync waves

| Wave | Applications |
|---|---|
| -3 | `namespace-flights`, `projects`, `argocd` |
| -2 | `istio-base`, `external-secrets`, `aws-load-balancer-controller` |
| -1 | `istiod`, `clustersecretstores`, `storageclass-gp3`, `metrics-server` |
| 0 | `istio-gateway`, `cluster-autoscaler`, `flights-api-eks`, `flights-web-eks`, `flights-worker-eks`, `mesh-flights` |
| 1 | `istio-ingress-alb` (the Ingress that makes the ALB) |

Traffic: ALB -> Istio ingress gateway (pod IPs, health check on 15021) -> Gateway/VirtualService -> `flights-web` (nginx) -> `/api/` -> `flights-api`.

## Bootstrap (one time per cluster)

These are the documented exceptions to "everything through ArgoCD": ArgoCD cannot install itself or create the Application that manages it.

```bash
export AWS_PROFILE=aws-lab
aws eks update-kubeconfig --region eu-north-1 --name flights-dev-eks

# 1. ArgoCD, same chart version and values as the `argocd` Application
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd --version 10.3.3 -n argocd --create-namespace \
  -f infra/helm-values/argocd.yaml -f infra/helm-values/argocd-eks.yaml

# 2. AppProject platform-infra, then the root Application
kubectl apply -f argocd/eks/projects/platform-infra.yaml
kubectl apply -f argocd/eks/bootstrap/platform-root-eks.yaml
```

From here ArgoCD adopts itself through `apps/argocd.yaml`. Merging changes to the two applied files does NOT update the live objects; re-apply them.

## Check

```bash
kubectl get applications -n argocd
kubectl get ingress -n istio-system istio-ingressgateway   # ADDRESS = the ALB hostname
```

Teardown order is in `DESTROY.md` of the infra repo: delete the Ingress and the PVCs first, then `terraform destroy`.
