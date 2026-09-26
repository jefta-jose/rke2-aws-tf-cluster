{{- define "rok-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rok-app.labels" -}}
helm.sh/chart: {{ include "rok-app.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: rok-app
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
