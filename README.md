# flights-platform-manifests

GitOps desired state for the flights platform: Helm charts, ArgoCD
Applications/ApplicationSets/AppProjects, ExternalSecrets and monitoring
config. ArgoCD syncs this repo; nothing here is applied by hand except the
bootstrap exceptions listed in [CLAUDE.md](CLAUDE.md).

| Repo | Contents |
|------|----------|
| [flights-platform](https://github.com/danahiju/flights-platform) | App code: flights-api, flights-worker, flights-web, CI |
| **flights-platform-manifests** (this one) | Helm charts + ArgoCD objects (source of truth) |
| [flights-platform-infra](https://github.com/danahiju/flights-platform-infra) | Terraform |

## Architecture

```
 user ──► flights-web (nginx) ──/api/*──► flights-api ──X-API-Key──► Amadeus Travel Builder APIs
                                             │    │
                                        Postgres  Redis ◄── flights-worker (CronJob, 6 h)
```

- CI in the app repo pushes images to GHCR and a GitHub App bumps the tags in
  `charts/*/values*.yaml`. ArgoCD syncs **staging** automatically (prune +
  selfHeal). **Production** is manual sync only, with a weekend deny window.
- Chain: `platform-root` → `argocd/apps/` → AppProjects and ApplicationSets →
  Applications → workloads.

## Environments

| Environment | Where | Sync |
|---|---|---|
| staging | k3s homelab (pop-os) | automatic |
| production | k3s homelab (pop-os) | manual + weekend sync window |
| EKS | AWS, only for assignment evidence (`argocd/eks/`) | own ArgoCD |

## How the Amadeus API key is provisioned (staging)

The key is a real third-party credential, so it can go neither into Git nor
into the `fake-local` store (whose values live in Git).

```
 kubectl-created Secret external-secrets/flights-amadeus   { api-key }   ← by hand, never in Git
        │   read by ClusterSecretStore "homelab-secrets" (ESO Kubernetes provider,
        │   argocd/platform-infra/clustersecretstores, read-only Role)
        ▼
 ExternalSecret staging/flights-api-staging-amadeus          (charts/flights-api)
        ▼
 Secret staging/flights-api-staging-amadeus   { AMADEUS_API_KEY }
        ├──► flights-api pods     envFrom, optional: true
        └──► flights-worker Job   secretKeyRef, optional: true
```

Create or rotate it (the key never touches a file, the screen, shell history or
the process list):

```bash
read -rs AMADEUS_API_KEY
printf %s "$AMADEUS_API_KEY" | kubectl create secret generic flights-amadeus \
  -n external-secrets --from-file=api-key=/dev/stdin --dry-run=client -o yaml \
  | kubectl apply -f -
unset AMADEUS_API_KEY
```

Without it, the ExternalSecret reports `SecretSyncedError`, the
`flights-api-staging` Application shows Degraded, and searches answer 503
`provider_not_configured`. Health, readiness, bookings and `/deals` keep working.
Details: CLAUDE.md, "Bootstrap: homelab source secrets".

The `amadeus` block in `charts/flights-api/values.yaml` is **off by default** and
enabled only in `values-staging.yaml`, so production renders exactly what it
rendered before.

## Caching

Redis in front of every Amadeus call (searches 10 min, airline names 7 days,
airport/city typeahead 1 day, deals 7 h). Full table: the app repo README.

## Layout

```
argocd/bootstrap/       platform-root (applied by hand)
argocd/projects/        AppProjects platform-infra (by hand) and platform-apps
argocd/apps/            Applications (platform components, worker, web, ...)
argocd/appsets/         ApplicationSet flights-api (staging + production)
argocd/platform-infra/  ClusterSecretStores chart (aws, fake-local, homelab-secrets)
argocd/eks/             Everything EKS-specific
charts/                 flights-api, flights-worker, flights-web
monitoring/             Dashboards and alert rules as ConfigMaps
docs/                   Observability notes
```

## Not done yet

- Production and EKS: no Amadeus key wiring. They need the key in AWS Secrets
  Manager (`aws-secrets-manager` store) and `amadeus.enabled: true` in their
  values. Production then needs its manual sync.
- Key rotation needs a flights-api pod restart (`envFrom` is read at start; no
  Reloader installed).
- Egress: the mesh allows any outbound host. A `ServiceEntry` for
  `api.amadeus.com` plus `REGISTRY_ONLY` would tighten it.
- `docs/observability.md` and two dashboard ConfigMaps still contain Spanish
  text; they were not part of this change.

### Future work

- Watchlist: track a route and alert on price drops. Not started.
