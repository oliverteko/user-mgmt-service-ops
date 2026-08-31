{{/*
Expand the name of the chart.
*/}}
{{- define "user-mgmt-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "user-mgmt-service.fullname" -}}
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
{{- define "user-mgmt-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "user-mgmt-service.labels" -}}
helm.sh/chart: {{ include "user-mgmt-service.chart" . }}
{{ include "user-mgmt-service.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "user-mgmt-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "user-mgmt-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Component-scoped labels/selectors. Pass a dict "component" "backend|frontend|postgres" "context" $
*/}}
{{- define "user-mgmt-service.componentSelectorLabels" -}}
{{ include "user-mgmt-service.selectorLabels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "user-mgmt-service.componentLabels" -}}
{{ include "user-mgmt-service.labels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Build a "repository:tag" image reference. Pass a dict "image" .Values.<component>.image "context" $
*/}}
{{- define "user-mgmt-service.image" -}}
{{- $tag := .image.tag | default .context.Chart.AppVersion -}}
{{- printf "%s:%s" .image.repository (toString $tag) -}}
{{- end -}}

{{/*
NOTE on naming: resource names below (postgres, backend, frontend, app-config, app-secret)
are intentionally kept as literal/values-driven strings rather than prefixed via
"user-mgmt-service.fullname". The app's own runtime config hardcodes DNS names like
"postgres:5432" and "http://backend:8080" (SPRING_DATASOURCE_URL, INTERNAL_API_URL).
Renaming these per-release would break that wiring for no benefit, since this chart is
designed for one release per namespace (matching current usage). Labels/selectors still use
the standard helpers above so the chart behaves conventionally and lints cleanly.
*/}}
