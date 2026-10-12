{{- define "nimbus-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "nimbus-app.labels" -}}
helm.sh/chart: {{ include "nimbus-app.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: nimbus
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
