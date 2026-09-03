# flights-platform-manifests

GitOps desired state: Helm charts, ArgoCD objects, Terraform. No application source.
App code lives in the separate repo `flights-platform`.

## Environments — there are exactly two
- `pop-os` — k3s v1.36.3+k3s1 homelab, always-on, reached over Tailscale.
  All development and validation happens here. Free.
- AWS EKS — stood up at the END, only to capture assignment evidence, then destroyed.
kind is NOT used. Never propose it.

## GitOps rules
- No `kubectl apply` for workloads. Everything flows through ArgoCD.
- TWO documented exceptions, applied manually: argocd/bootstrap/platform-root.yaml
  and argocd/projects/platform-infra.yaml. ArgoCD cannot bootstrap the Application
  that manages itself. Merging changes to these files does NOT update the live
  object — they must be re-applied with kubectl.
- AppProjects split by privilege: `platform-infra` holds cluster-scoped resources
  (CRDs, ClusterRoles, webhooks); `platform-apps` holds namespaced workloads.
- Helm has no environment auto-detection. Values files are selected explicitly.

## Istio — webhook drift (solved, do not re-derive)
- TWO separate ValidatingWebhookConfigurations drift, not one:
    istio-base -> istiod-default-validator
    istiod     -> istio-validator-istio-system
  Both are VALIDATING webhooks, not mutating.
- Cause: istiod (field manager `pilot-discovery`) patches them at runtime —
  injects caBundle AND flips failurePolicy from Ignore to Fail.
- Fix: ignoreDifferences with `managedFieldsManagers: [pilot-discovery]`, NOT
  jsonPointers. Requires BOTH `ServerSideApply=true` (so the API server tracks
  per-field ownership) and `RespectIgnoreDifferences=true` (or sync still applies
  the Git version over those fields).
- Separate drift cause: `helm: {}` in an Application spec. The API server discards
  empty objects, so Git declares a field the cluster will never have. Remove it.

## Sync waves
istio-base (-2, CRDs) -> istiod (-1) -> istio-gateway (0)
external-secrets (-2, CRDs) -> clustersecretstores (-1) -> apps (0)
ClusterSecretStores need `SkipDryRunOnMissingResource=true` on first sync.

## Secrets
- No secrets in Git. ExternalSecret + ClusterSecretStore via ESO.
- Two stores: `aws-secrets-manager` (IRSA) for EKS, `fake-local` for k3s.
  IRSA needs an EKS OIDC provider, which k3s does not have.
- The ESO-owned Secret name MUST equal flights-api.fullname: both the Deployment's
  envFrom and the postgresql subchart's auth.existingSecret depend on it.
- Bitnami postgresql: auth.existingSecret + secretKeys.userPasswordKey: DB_PASSWORD
  + enablePostgresUser: false (else the StatefulSet demands a postgres-password key
  the ESO Secret does not carry, and fails CreateContainerConfigError).

## Sync policy asymmetry — assignment requirement, get it exact
- staging: `automated` with prune and selfHeal. Takes changes from main immediately.
- production: manual sync only, plus a syncWindow blocking weekend syncs.

## AWS cost discipline — ~$100 credits, not reimbursed
- Teardown script must exist and be reviewed BEFORE the first `terraform apply`.
- Flag anything exceeding free tier before running it. Never incur cost silently.
- NAT Gateway bills hourly regardless of traffic.
- Delete Kubernetes Services/Ingresses BEFORE `terraform destroy` — load balancers
  created by the AWS Load Balancer Controller are invisible to Terraform state.

## Hard rules
- Never run `terraform apply` without asking first.
- Never `kubectl apply` anything except the two bootstrap files above.
