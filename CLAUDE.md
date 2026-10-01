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
- platform-infra.yaml stays a bootstrap exception ON PURPOSE. platform-root (and
  every Application under argocd/apps/) runs under platform-infra. If ArgoCD
  managed it, a bad commit could remove a destination or resource kind that
  platform-root needs, and platform-root could then no longer sync the commit
  that fixes it — only a manual `kubectl apply` would recover.
- The AppProject platform-apps is NOT an exception: it is managed by the
  Application `projects` (argocd/apps/projects.yaml, project `platform-infra`),
  whose `directory.include` selects ONLY platform-apps.yaml, so platform-infra.yaml
  is never picked up by accident. `prune: false`: deleting the file does not
  delete the AppProject. Adopting it corrects drift: Git had the syncWindow
  `timeZone: Asia/Jerusalem` but the hand-applied live object did not, so the
  weekend deny window was evaluated in UTC until the first sync of `projects`.
- ApplicationSets are NOT an exception: argocd/appsets/ is managed by the
  Application `appsets` (argocd/apps/appsets.yaml, project `platform-infra`
  because the objects live in the `argocd` namespace), itself created by
  platform-root. Merging a change under argocd/appsets/ updates the live
  ApplicationSet. `appsets` syncs with `prune: false`: deleting a file there
  does not delete the ApplicationSet.
- Every ApplicationSet sets `syncPolicy.preserveResourcesOnDeletion: true`. The
  chain platform-root -> appsets -> ApplicationSet -> Applications -> workloads
  cascades deletes by default: losing the ApplicationSet (a bad merge, a rename,
  removing appsets.yaml while platform-root prunes) would delete the generated
  Applications and, through their finalizer, the Deployments, StatefulSets and
  PVCs behind them — including the Postgres data. With the flag the generated
  Applications carry no resources finalizer, so the workloads are left running.
- AppProjects split by privilege: `platform-infra` holds cluster-scoped resources
  (CRDs, ClusterRoles, webhooks); `platform-apps` holds namespaced workloads.
- Helm has no environment auto-detection. Values files are selected explicitly.

## Bootstrap: ghcr-pull (image pull secret, created by hand)
- `ghcr-pull` is a `kubernetes.io/dockerconfigjson` Secret created manually, ONE
  PER NAMESPACE that pulls from GHCR (`staging` and `production`). The charts only
  reference it (`serviceAccount.imagePullSecrets`); they never create it.
- It is bootstrap, like the two files above, and the third manual exception: ESO
  cannot deliver it on the homelab, because the `fake-local` provider keeps its
  values in Git and the token would end up committed.
- Token: GitHub CLASSIC personal access token with ONLY the `read:packages`
  scope. GHCR does not support fine-grained tokens. Expiry: 30 days.
  Next rotation due before 2026-10-30.
- Rotation procedure (never paste the token into a command, a file or Git):
  1. Create the new classic token (read:packages only, 30 days), then load it
     into the shell without echo or history: `read -rs GHCR_TOKEN`
  2. Verify its scopes — the header must list exactly `read:packages`:
       curl -sI -H "Authorization: Bearer $GHCR_TOKEN" https://api.github.com/user \
         | grep -i x-oauth-scopes
  3. Replace the Secret in EACH namespace (staging, production):
       kubectl create secret docker-registry ghcr-pull -n <namespace> \
         --docker-server=ghcr.io --docker-username=<github-user> \
         --docker-password="$GHCR_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
  4. Verify with a throwaway pod using imagePullPolicy Always. IfNotPresent
     proves nothing: it is satisfied from the node's image cache without ever
     contacting the registry.
       kubectl run ghcr-pull-test -n <namespace> --restart=Never \
         --image=ghcr.io/danahiju/flights-api:<tag> --image-pull-policy=Always \
         --overrides='{"spec":{"imagePullSecrets":[{"name":"ghcr-pull"}]}}' \
         --command -- true
       kubectl describe pod ghcr-pull-test -n <namespace>   # "Successfully pulled image"
       kubectl delete pod ghcr-pull-test -n <namespace>
  5. Revoke the old token in GitHub, `unset GHCR_TOKEN`, and update the
     rotation date above.
- Does NOT apply on EKS: images come from ECR and the node IAM role grants the
  pull. No pull secret; leave `serviceAccount.imagePullSecrets` empty there.

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

## State outside Git (solved, do not re-derive)
- ArgoCD selfHeal does NOT retry a failed sync on the same Git commit. After an
  automated sync fails, ArgoCD backs off and will not retry until the target
  revision changes or someone triggers a sync manually. An Application can sit
  OutOfSync for days with `selfHeal: true` and never retry. Restarting the
  application-controller does NOT trigger a retry. Force it with:
    kubectl patch application <name> -n argocd --type merge \
      -p '{"operation":{"initiatedBy":{"username":"<user>"},"sync":{"revision":"HEAD"}}}'
- `status.operationState.message` can be days stale — it describes the LAST
  operation that ran, not the current state. Always check
  `status.operationState.finishedAt` against current cluster time before trusting
  the error message. A four-day-old discovery error ("failed to discover server
  resources for group version external-secrets.io/v1") was read as current and
  sent the diagnosis down the wrong path. The CRD was Established=True and the
  API server was serving v1 the whole time.
- Postgres keeps the ORIGINAL password. initdb only runs on an empty data
  directory, so the PVC holds the password written to pg_authid at first boot
  even after ESO rotates the Secret. Fix: delete the PVC, then delete the pod to
  release the pvc-protection finalizer — the StatefulSet recreates both from
  volumeClaimTemplates. Evidence initdb actually ran: the log line
  `Creating user flights` appears only on a fresh data directory.
  ALTER USER is NOT the fix.
- Diagnostic order: when an Application is OutOfSync with selfHeal enabled but
  never converges, check `operationState.finishedAt` FIRST. If it is old, no sync
  has been attempted and the error message is not evidence about the present.

## AWS cost discipline — ~$100 credits, not reimbursed
- Teardown script must exist and be reviewed BEFORE the first `terraform apply`.
- Flag anything exceeding free tier before running it. Never incur cost silently.
- NAT Gateway bills hourly regardless of traffic.
- Delete Kubernetes Services/Ingresses BEFORE `terraform destroy` — load balancers
  created by the AWS Load Balancer Controller are invisible to Terraform state.

## Hard rules
- Never run `terraform apply` without asking first.
- Never `kubectl apply` anything except the two bootstrap files above and the
  `ghcr-pull` Secret (see "Bootstrap: ghcr-pull").

## Layout
infra/terraform/     EKS, VPC, IAM, ECR, S3+DynamoDB backend
infra/helm-values/   platform chart overrides
charts/flights-api/  app Helm chart + values{,-staging,-production}.yaml
argocd/apps/         Application manifests
argocd/appsets/      ApplicationSets
argocd/projects/     AppProjects
