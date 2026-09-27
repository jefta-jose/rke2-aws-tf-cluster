{{- define "rock-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rock-app.labels" -}}
helm.sh/chart: {{ include "rock-app.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: rock-app
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
