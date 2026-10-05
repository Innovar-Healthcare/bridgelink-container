{{/*
Expand the name of the chart.
*/}}
{{- define "bridgelink.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "bridgelink.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "bridgelink.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "bridgelink.labels" -}}
helm.sh/chart: {{ include "bridgelink.chart" . }}
{{ include "bridgelink.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "bridgelink.selectorLabels" -}}
app: bl
app.kubernetes.io/name: {{ include "bridgelink.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "bridgelink.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "bridgelink.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
WebAdmin selector labels. Deliberately NOT built on bridgelink.selectorLabels: the BridgeLink
Service selects on `app: bl`, so WebAdmin pods carrying it would receive BridgeLink traffic.
*/}}
{{- define "bridgelink.webadminSelectorLabels" -}}
app: webadmin
app.kubernetes.io/name: {{ include "bridgelink.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: webadmin
{{- end }}

{{/*
WebAdmin labels
*/}}
{{- define "bridgelink.webadminLabels" -}}
helm.sh/chart: {{ include "bridgelink.chart" . }}
{{ include "bridgelink.webadminSelectorLabels" . }}
app.kubernetes.io/version: {{ .Values.webadmin.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Bundled PostgreSQL selector labels. Exactly what the Deployment's spec.selector has always used, so
an existing release can upgrade: a Deployment's selector cannot be changed after it is created.
*/}}
{{- define "bridgelink.postgresSelectorLabels" -}}
app: postgres
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Bundled PostgreSQL labels. Deliberately NOT built on bridgelink.labels, which carries `app: bl`: the
templates used to add `app: postgres` and then include it, which rendered a duplicate `app` key, and
the later `app: bl` won.
*/}}
{{- define "bridgelink.postgresLabels" -}}
helm.sh/chart: {{ include "bridgelink.chart" . }}
{{ include "bridgelink.postgresSelectorLabels" . }}
app.kubernetes.io/name: {{ include "bridgelink.name" . }}
app.kubernetes.io/component: postgres
app.kubernetes.io/version: {{ .Values.postgres.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Database connection settings. A non-empty bridgelink.environment value is passed through unchanged, so
an external database (for example Amazon RDS) can use any JDBC scheme, port and URL parameters. An
empty value falls back to the bundled PostgreSQL when postgres.enabled is true. Each helper renders
nothing when there is no value at all, and the Deployment then omits that variable.

Values files copied from older chart versions carry the old defaults, which were template strings
such as "{{ .Values.postgres.credentials.username }}" that the chart ignored. Those are rendered with
tpl, so they resolve to what they always meant; any value without "{{" is never templated.
*/}}
{{- define "bridgelink.databaseValue" -}}
{{- $v := toString (index . 0) -}}
{{- if contains "{{" $v -}}
{{- tpl $v (index . 1) -}}
{{- else -}}
{{- $v -}}
{{- end -}}
{{- end }}

{{- define "bridgelink.databaseUrl" -}}
{{- $env := .Values.bridgelink.environment -}}
{{- if $env.MP_DATABASE_URL -}}
{{- include "bridgelink.databaseValue" (list $env.MP_DATABASE_URL $) -}}
{{- else if .Values.postgres.enabled -}}
{{- printf "jdbc:postgresql://%s-postgres:%v/%s" (include "bridgelink.fullname" .) .Values.postgres.service.port .Values.postgres.credentials.database -}}
{{- else if ne (lower (toString (default "" $env.MP_DATABASE))) "derby" -}}
{{- fail "postgres.enabled is false, so set bridgelink.environment.MP_DATABASE_URL to your database's JDBC URL (and MP_DATABASE_USERNAME / MP_DATABASE_PASSWORD), or set postgres.enabled=true for the bundled evaluation database" -}}
{{- end -}}
{{- end }}

{{- define "bridgelink.databaseUsername" -}}
{{- if .Values.bridgelink.environment.MP_DATABASE_USERNAME -}}
{{- include "bridgelink.databaseValue" (list .Values.bridgelink.environment.MP_DATABASE_USERNAME $) -}}
{{- else if .Values.postgres.enabled -}}
{{- .Values.postgres.credentials.username -}}
{{- end -}}
{{- end }}

{{- define "bridgelink.databasePassword" -}}
{{- if .Values.bridgelink.environment.MP_DATABASE_PASSWORD -}}
{{- include "bridgelink.databaseValue" (list .Values.bridgelink.environment.MP_DATABASE_PASSWORD $) -}}
{{- else if .Values.postgres.enabled -}}
{{- .Values.postgres.credentials.password -}}
{{- end -}}
{{- end }}

{{/*
Service fields shared by the BridgeLink, listener and WebAdmin Services, from one service values
block. loadBalancerSourceRanges and loadBalancerClass are rendered only for type LoadBalancer: the
API server rejects both on any other type.
*/}}
{{- define "bridgelink.serviceSpec" -}}
type: {{ .type }}
{{- if eq .type "LoadBalancer" }}
{{- with .loadBalancerClass }}
loadBalancerClass: {{ . | quote }}
{{- end }}
{{- with .loadBalancerSourceRanges }}
loadBalancerSourceRanges:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Ports from bridgelink.extraPorts, as Service ports targeting the container ports of the same name.
*/}}
{{- define "bridgelink.extraServicePorts" -}}
{{- range . }}
- port: {{ .port | default .containerPort }}
  targetPort: {{ .name }}
  protocol: {{ .protocol | default "TCP" }}
  name: {{ .name }}
{{- end }}
{{- end }}

{{/*
Fails the render on extraPorts that Kubernetes would reject only at apply time, after some objects
were already updated: a repeated name, a container port already in use (8443 and 8080 are the
server's own), or a Service port repeated on the Service the extra ports join. Port and protocol
together must be unique, so UDP and TCP may share a number.
*/}}
{{- define "bridgelink.validateExtraPorts" -}}
{{- $svc := .Values.bridgelink.service }}
{{- $names := list }}
{{- $container := list "8443/TCP" "8080/TCP" }}
{{- $service := list }}
{{- if not .Values.bridgelink.listenerService.enabled }}
{{- $service = append $service (printf "%d/TCP" (int $svc.ports.https)) }}
{{- if $svc.ports.http }}
{{- $service = append $service (printf "%d/TCP" (int $svc.ports.http)) }}
{{- end }}
{{- end }}
{{- range .Values.bridgelink.extraPorts }}
{{- $proto := .protocol | default "TCP" }}
{{- $c := printf "%d/%s" (int .containerPort) $proto }}
{{- $s := printf "%d/%s" (int (.port | default .containerPort)) $proto }}
{{- if has .name $names }}
{{- fail (printf "bridgelink.extraPorts: the name %q is used twice" .name) }}
{{- end }}
{{- if has $c $container }}
{{- fail (printf "bridgelink.extraPorts %q: container port %s is already in use (8443 and 8080 are BridgeLink's own)" .name $c) }}
{{- end }}
{{- if has $s $service }}
{{- fail (printf "bridgelink.extraPorts %q: Service port %s is already in use on that Service" .name $s) }}
{{- end }}
{{- $names = append $names .name }}
{{- $container = append $container $c }}
{{- $service = append $service $s }}
{{- end }}
{{- end }}
