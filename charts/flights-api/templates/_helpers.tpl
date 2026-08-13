{{/*
Expand the name of the chart.
*/}}
{{- define "flights-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name. Truncated to 63 chars because
Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "flights-api.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "flights-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "flights-api.labels" -}}
helm.sh/chart: {{ include "flights-api.chart" . }}
{{ include "flights-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "flights-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "flights-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Name of the ServiceAccount to use.
*/}}
{{- define "flights-api.serviceAccountName" -}}
{{- $sa := .Values.serviceAccount | default dict -}}
{{- if $sa.create -}}
{{- default (include "flights-api.fullname" .) $sa.name -}}
{{- else -}}
{{- default "default" $sa.name -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the PostgreSQL host.

When the bundled Bitnami postgresql subchart is enabled, the host is derived
from the release name the same way the subchart derives its own service name
(release name alone if it already contains "postgresql", otherwise
"<release-name>-postgresql") — this assumes the subchart is used with its
own default naming, i.e. postgresql.nameOverride/fullnameOverride are not set.
When the subchart is disabled (e.g. production, pointing at RDS),
.Values.config.DB_HOST is used verbatim. This keeps values files free of
hardcoded, release-name-dependent hostnames.
*/}}
{{- define "flights-api.postgresqlHost" -}}
{{- if .Values.postgresql.enabled -}}
{{- if contains "postgresql" .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-postgresql" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- else -}}
{{- .Values.config.DB_HOST -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the Redis URL.

Same pattern as the PostgreSQL host: when the bundled Bitnami redis subchart
is enabled, the URL is built from the release-derived master service name
(standalone architecture: "<release-name>-master" or "<release-name>-redis-master",
mirroring the subchart's own naming). When disabled (e.g. production, pointing
at ElastiCache), .Values.config.REDIS_URL is used verbatim.
*/}}
{{- define "flights-api.redisUrl" -}}
{{- if .Values.redis.enabled -}}
{{- $host := "" -}}
{{- if contains "redis" .Release.Name -}}
{{- $host = printf "%s-master" .Release.Name -}}
{{- else -}}
{{- $host = printf "%s-redis-master" .Release.Name -}}
{{- end -}}
{{- if .Values.redis.auth.enabled -}}
{{- printf "redis://:%s@%s:6379/0" .Values.redis.auth.password $host -}}
{{- else -}}
{{- printf "redis://%s:6379/0" $host -}}
{{- end -}}
{{- else -}}
{{- .Values.config.REDIS_URL -}}
{{- end -}}
{{- end -}}
