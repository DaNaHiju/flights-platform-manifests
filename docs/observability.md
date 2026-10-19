# Observabilidad de flights-api (homelab pop-os)

Notas de estudio. Todo lo de abajo existe en el repo o se verificó el 2026-10-19.

## 1. Mapa del stack

kube-prometheus-stack 92.3.0 en ns `monitoring` (Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter). Retención 2d / 2GB.

**Qué recoge Prometheus hoy** (`count by (job) (up)`): kubelet (incluye cAdvisor, de ahí `container_memory_working_set_bytes`), apiserver, node-exporter, kube-state-metrics, operator, Alertmanager, Grafana, Prometheus, `pilot` (istiod, ServiceMonitor) y `monitoring/envoy-stats` (3 targets).

**envoy-stats** es el PodMonitor oficial de Istio (`additionalPodMonitors`). Tres pasos de relabeling importan:
- `keep` del contenedor `istio-proxy`: solo se scrapea el sidecar, no la app.
- `keep` de pods con la annotation `prometheus.io/scrape`.
- `__address__` se arma con la annotation `prometheus.io/port` = **15020**. Istio escribe ahí el puerto de pilot-agent, que hace *merge* de las métricas de Envoy con las de la app (`enablePrometheusMerge: true`).

**Qué no recoge y por qué**
- etcd, scheduler, controller-manager y kube-proxy están `enabled: false` en los values: k3s los embebe en un solo proceso, sus endpoints estándar no existen y los targets quedarían DOWN falsos.
- CoreDNS también está `enabled: false`: su Service headless vive en `kube-system`, que `platform-infra` no admite como destination.
- Métricas propias de la app (`http_requests_total`, `bookings_created_total`, `provider_errors_total`, `http_request_duration_seconds`): `/metrics` responde 200, pero el merge de :15020 no las incluye. El pod no tiene las annotations `prometheus.io/*` en el template del Deployment, así que Istio no sabe dónde está el endpoint de la app (las que se ven en el pod vivo las inyecta Istio apuntando a 15020). Hacen falta `prometheus.io/scrape: "true"`, `port: "8000"`, `path: "/metrics"` en el pod template.

## 2. Las queries del dashboard "flights-api RED"

Todas usan métricas Istio de `destination_workload="flights-api-staging"`, salvo memoria (cAdvisor).

```promql
sum(rate(istio_requests_total{destination_workload="flights-api-staging"}[5m]))
```
**Request rate.** `rate()` convierte el counter acumulado en requests/s promedio sobre 5m (maneja resets). `sum()` colapsa todas las series (una por pod, código, origen) en una.

```promql
(sum(rate(istio_requests_total{...,response_code=~"5.."}[5m])) or vector(0))
  / sum(rate(istio_requests_total{...}[5m])) * 100
```
**Error rate %.** Cociente de 5xx sobre total. `or vector(0)` devuelve 0 cuando no hay series 5xx; sin eso el numerador estaría vacío y el panel mostraría "no data" en vez de 0%.

```promql
histogram_quantile(0.95,
  sum by (le) (rate(istio_request_duration_milliseconds_bucket{...}[5m])))
```
**Latencia p95.** El histogram guarda counters por bucket `le`. Se hace `rate` por bucket, `sum by (le)` conserva solo el eje de buckets (suma entre pods) y `histogram_quantile` interpola el percentil 95 (en ms). Es una estimación: la precisión depende de los límites de los buckets.

```promql
sum by (container) (container_memory_working_set_bytes{
  pod=~"flights-api-staging-[a-z0-9]{8,10}-[a-z0-9]{5}", container!=""})
```
**Memoria por contenedor.** `sum by (container)` separa app e `istio-proxy`. `container!=""` descarta la serie agregada del pod. **Por qué cambió el regex** (commit 99068cf): `flights-api-staging-[a-z0-9]+-[a-z0-9]+` también casaba `flights-api-staging-postgresql-0`. Ahora fija el hash del ReplicaSet (8-10 caracteres) y el sufijo del pod (5), que solo existen en pods de un Deployment.

## 3. Alertas (`monitoring/dashboards/flights-api-alerts.yaml`)

Una PrometheusRule, grupo `flights-api`. Prometheus la toma de cualquier namespace porque `ruleSelectorNilUsesHelmValues: false`.

| Alerta | expr | for | severity |
|---|---|---|---|
| FlightsApiHighErrorRate | `(sum(rate(istio_requests_total{destination_workload="flights-api-staging",response_code=~"5.."}[5m])) or vector(0)) / sum(rate(istio_requests_total{destination_workload="flights-api-staging"}[5m])) > 0.01` | 5m | warning |
| FlightsApiDown | `kube_deployment_status_replicas_available{namespace="staging",deployment="flights-api-staging"} == 0` | 1m | critical |

**Ciclo.** En cada evaluación, si la expr devuelve series, la alerta pasa a **pending**; si la condición se mantiene durante `for`, pasa a **firing** y se envía a Alertmanager; si la expr deja de devolver series, vuelve a **inactive**. Sin tráfico, HighErrorRate da 0/0 = NaN: no hay serie que cumpla `> 0.01` y no dispara.

**Alertmanager sin receiver.** Verificado en el Secret: el único receiver es `"null"` y es el de la ruta por defecto (`group_by: namespace`, `repeat_interval: 12h`). Las alertas llegan y se ven en la UI de Alertmanager y en la serie `ALERTS` de Prometheus, pero no salen a ningún lado (ni mail, ni Slack). FlightsApiDown llegó a firing el 2026-10-19 y es visible en `max_over_time(ALERTS{alertname="FlightsApiDown",alertstate="firing"}[2h])`.

## 4. Incidente: escalar a 0 no disparaba FlightsApiDown

- **Síntoma.** Con `flights-api-staging` escalado a 0 la alerta no llegaba a pending: el Deployment volvía a 1 réplica antes de cumplir `for: 1m`.
- **Hipótesis descartadas.** Escalar a mano no alcanza porque `selfHeal: true` revierte el cambio. Quitar el auto-sync de la Application con un patch al `syncPolicy` tampoco: el controlador que genera la Application (el ApplicationSet) lo deshacía.
- **Causa.** Dos capas de reconciliación desde Git: `selfHeal` sobre el Deployment y el generador de la Application sobre su `syncPolicy`. Cualquier cambio manual aguas abajo era revertido.
- **Fix.** Pausar al que reconcilia: `argocd-application-controller` a 0 réplicas, auto-sync de `platform-root` pausado, Deployment a 0 y esperar `for: 1m`. Después se restauró todo (controller 1/1, `platform-root` con `automated: prune+selfHeal` como en Git, Deployment 1/1) y se verificó Synced/Healthy.
- **Lección.** Para probar una alerta sobre un recurso gestionado por GitOps hay que pausar a quien lo reconcilia, no solo tocar el recurso, y verificar Synced/Healthy al restaurar. Ver también `status.operationState.finishedAt` antes de creerle a un mensaje de error de ArgoCD.

## 5. Loki y Jaeger (no desplegados)

**Loki (logs).** Resuelve "¿qué dijo el pod X cuando falló?" sin `kubectl logs` pod por pod y sobreviviendo a reinicios. Va de la mano de un agente que lea los logs de cada nodo (Alloy, que reemplaza a Promtail) y del datasource en Grafana → Explore. Indexa solo labels (namespace, pod, container), así que es barato frente a Elasticsearch. Recomendarlo cuando el cliente ya tiene Prometheus/Grafana y necesita correlacionar un pico de métricas con los logs de ese momento. Aviso: para sacarlo de una prueba hace falta storage objeto (S3) y retención definida.

**Jaeger (tracing).** Resuelve "¿en qué hop de la cadena api → worker → DB se fue la latencia?", que las métricas agregadas no muestran. Va de la mano de los sidecars de Istio (generan los spans), un `extensionProvider` en istiod, un recurso `Telemetry` con el porcentaje de sampling y, sobre todo, **que la app propague los headers** (`traceparent`, `x-b3-*`); sin eso cada hop es un trace de un solo span. Recomendarlo con muchos microservicios y problemas de latencia entre ellos; con un monolito o dos servicios, las métricas RED alcanzan.
