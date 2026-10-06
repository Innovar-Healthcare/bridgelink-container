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
"true" when an extraEnv entry sets the named variable. Takes (list $ "NAME").
*/}}
{{- define "bridgelink.inExtraEnv" -}}
{{- $name := index . 1 -}}
{{- range (index . 0).Values.bridgelink.extraEnv -}}
{{- if eq .name $name -}}true{{- end -}}
{{- end -}}
{{- end }}

{{/*
A value as the container receives it: a missing or null value is empty,
anything else is its string form, so `false` stays "false" as it always rendered.
*/}}
{{- define "bridgelink.envString" -}}
{{- if not (kindIs "invalid" .) -}}{{- toString . -}}{{- end -}}
{{- end }}

{{/*
The maximum heap in MiB: bridgelink.heapPercentage of resources.limits.memory, rounded down. Renders
nothing when either is unset. The image's own vmoptions carry -Xmx256m, which beats any
-XX:MaxRAMPercentage, so the chart works the size out here and passes it as a plain -Xmx instead.
*/}}
{{- define "bridgelink.heapMi" -}}
{{- $pct := .Values.bridgelink.heapPercentage -}}
{{- $limit := include "bridgelink.envString" (dig "limits" "memory" nil (.Values.bridgelink.resources | default dict)) | trim -}}
{{- if and (not (kindIs "invalid" $pct)) $limit -}}
{{- if not (regexMatch "^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|k|M|G|T)?$" $limit) -}}
{{- fail (printf "bridgelink.resources.limits.memory %q is not a size the chart can read to work out the heap (use a form such as 2Gi or 2048Mi). Set the heap yourself with bridgelink.environment.MP_VMOPTIONS (for example \"1536\" for 1536 MB), or set bridgelink.heapPercentage to null to keep the image's default." $limit) -}}
{{- end -}}
{{- $number := regexReplaceAll "[A-Za-z]+$" $limit "" | float64 -}}
{{- $units := dict "" 1.0 "Ki" 1024.0 "Mi" 1048576.0 "Gi" 1073741824.0 "Ti" 1099511627776.0 "k" 1000.0 "M" 1000000.0 "G" 1000000000.0 "T" 1000000000000.0 -}}
{{- $bytes := mulf $number (get $units (regexFind "[A-Za-z]+$" $limit)) -}}
{{- $heap := int64 (floor (divf (mulf $bytes (float64 $pct)) (mulf 100.0 1048576.0))) -}}
{{- if lt $heap 64 -}}
{{- fail (printf "bridgelink.resources.limits.memory %q leaves a heap of %d MB, too small for BridgeLink to start. A plain number is bytes: write 2Gi or 2048Mi, not 2048. Or set the heap yourself with bridgelink.environment.MP_VMOPTIONS." $limit $heap) -}}
{{- end -}}
{{- $heap -}}
{{- end -}}
{{- end }}

{{/*
The MP_VMOPTIONS the chart sets: the heap from bridgelink.heapMi as a bare number of MB, which the
image writes over its -Xmx line, followed by bridgelink.environment.MP_VMOPTIONS. The heap is left
out when that value already sets one (a bare number, -Xmx or -XX:MaxHeapSize), and when
CUSTOM_VMOPTIONS is set: the image applies MP_VMOPTIONS after downloading that file, so the number
would replace the file's -Xmx.
*/}}
{{- define "bridgelink.vmoptions" -}}
{{- $user := include "bridgelink.envString" .Values.bridgelink.environment.MP_VMOPTIONS | trim -}}
{{- $setsHeap := false -}}
{{- range splitList "," $user -}}
{{- $opt := trim . -}}
{{- if or (regexMatch "^[0-9]+$" $opt) (hasPrefix "-Xmx" $opt) (hasPrefix "-XX:MaxHeapSize" $opt) -}}
{{- $setsHeap = true -}}
{{- end -}}
{{- end -}}
{{- $custom := or (include "bridgelink.envString" .Values.bridgelink.environment.CUSTOM_VMOPTIONS) (include "bridgelink.inExtraEnv" (list $ "CUSTOM_VMOPTIONS")) -}}
{{- $heap := "" -}}
{{- if not (or $setsHeap $custom) -}}
{{- $heap = include "bridgelink.heapMi" . -}}
{{- end -}}
{{- join "," (compact (list $heap $user)) -}}
{{- end }}

{{/*
Where each password comes from, as JSON: {"env": {VAR: {"secret", "key"}}, "data": {key: value}}.
"env" covers MP_DATABASE_PASSWORD, MP_KEYSTORE_STOREPASS, MP_KEYSTORE_KEYPASS and the bundled
PostgreSQL's POSTGRES_PASSWORD; "data" is what the chart's own Secret holds. A password is never
rendered into a pod spec. For each BridgeLink variable, the first of these that applies wins:

  1. an extraEnv entry of the same name (the chart then sets nothing);
  2. credentials.existingSecret, under the key named in credentials.keys, unless that name is empty
     (the database password is not read for Derby, which has none);
  3. for the keystore passwords, keystore.existingSecret under its fixed key names;
  4. the value from bridgelink.environment (or postgres.credentials), stored in the chart's Secret.
     An empty value is left out, and the image then treats the variable as unset.

POSTGRES_PASSWORD reads the same key as the database password from credentials.existingSecret, so
BridgeLink and the bundled PostgreSQL always agree, and otherwise postgres.credentials.password.
*/}}
{{- define "bridgelink.credentials" -}}
{{- $keys := .Values.bridgelink.credentials.keys | default dict -}}
{{- $existing := .Values.bridgelink.credentials.existingSecret -}}
{{- $keystoreSecret := .Values.bridgelink.keystore.existingSecret -}}
{{- $chart := printf "%s-credentials" (include "bridgelink.fullname" .) -}}
{{- $environment := .Values.bridgelink.environment -}}
{{- $derby := eq (lower (toString (default "" $environment.MP_DATABASE))) "derby" -}}
{{- $dbKey := toString ($keys.databasePassword | default "") -}}
{{- $env := dict -}}
{{- $data := dict -}}
{{- $vars := list (dict "name" "MP_DATABASE_PASSWORD" "key" (ternary "" $dbKey $derby) "keystoreKey" "" "chartKey" "database.password" "value" (include "bridgelink.databasePassword" .)) -}}
{{- $vars = append $vars (dict "name" "MP_KEYSTORE_STOREPASS" "key" (toString ($keys.keystoreStorepass | default "")) "keystoreKey" "keystore.storepass" "chartKey" "keystore.storepass" "value" (include "bridgelink.envString" $environment.MP_KEYSTORE_STOREPASS)) -}}
{{- $vars = append $vars (dict "name" "MP_KEYSTORE_KEYPASS" "key" (toString ($keys.keystoreKeypass | default "")) "keystoreKey" "keystore.keypass" "chartKey" "keystore.keypass" "value" (include "bridgelink.envString" $environment.MP_KEYSTORE_KEYPASS)) -}}
{{- range $vars -}}
{{- if include "bridgelink.inExtraEnv" (list $ .name) -}}
{{- else if and $existing .key -}}
{{- $_ := set $env .name (dict "secret" $existing "key" .key) -}}
{{- else if and $keystoreSecret .keystoreKey -}}
{{- $_ := set $env .name (dict "secret" $keystoreSecret "key" .keystoreKey) -}}
{{- else if .value -}}
{{- $_ := set $env .name (dict "secret" $chart "key" .chartKey) -}}
{{- $_ := set $data .chartKey .value -}}
{{- end -}}
{{- end -}}
{{- if .Values.postgres.enabled -}}
{{- if and $existing $dbKey -}}
{{- $_ := set $env "POSTGRES_PASSWORD" (dict "secret" $existing "key" $dbKey) -}}
{{- else if include "bridgelink.envString" .Values.postgres.credentials.password -}}
{{- $_ := set $env "POSTGRES_PASSWORD" (dict "secret" $chart "key" "postgres.password") -}}
{{- $_ := set $data "postgres.password" (include "bridgelink.envString" .Values.postgres.credentials.password) -}}
{{- end -}}
{{- end -}}
{{- toJson (dict "env" $env "data" $data) -}}
{{- end }}

{{/*
One env entry reading a password from a Secret. Takes (list "NAME" $entry), where $entry is a
non-empty value of bridgelink.credentials' "env".
*/}}
{{- define "bridgelink.credentialEnv" -}}
- name: {{ index . 0 }}
  valueFrom:
    secretKeyRef:
      name: {{ (index . 1).secret | quote }}
      key: {{ (index . 1).key | quote }}
{{- end }}

{{/*
The server ID every install shared before chart 0.9.0, when values.yaml set it by default. Existing
servers run as it and may be licensed against it.
*/}}
{{- define "bridgelink.legacyServerId" -}}
7d760af2-680a-4a19-b9a2-c4685df61ebc
{{- end }}

{{/*
"true" when an extraEnv entry supplies SERVER_ID, for example from a Secret.
*/}}
{{- define "bridgelink.serverIdFromExtraEnv" -}}
{{- range .Values.bridgelink.extraEnv -}}
{{- if eq .name "SERVER_ID" -}}true{{- end -}}
{{- end -}}
{{- end }}

{{/*
The server ID. Renders nothing when extraEnv supplies SERVER_ID, since that entry replaces the
chart's. Otherwise an explicit bridgelink.environment.SERVER_ID is always used. An upgrade with no ID keeps the
legacy ID: Core recovers and sends only queued messages stamped with its own server ID, so changing
an existing server's ID strands its queue. A new install with no ID fails rather than generating one,
because a generated ID would change on every render wherever lookup cannot see the cluster
(helm template, Argo CD).
*/}}
{{- define "bridgelink.serverId" -}}
{{- $id := toString (.Values.bridgelink.environment.SERVER_ID | default "") -}}
{{- if include "bridgelink.serverIdFromExtraEnv" . -}}
{{- else if trim $id -}}
{{- $id -}}
{{- else if .Release.IsUpgrade -}}
{{- include "bridgelink.legacyServerId" . -}}
{{- else -}}
{{- fail (printf "bridgelink.environment.SERVER_ID is required for a new install. For a new server, use this freshly generated ID: --set bridgelink.environment.SERVER_ID=%s (or set it in your values file). Record it: BridgeLink licenses are issued against it. If this release replaces an existing server (a restore, a migration, a reinstall against the same database, or an Argo CD application), set that server's ID instead; chart versions before 0.9.0 defaulted to %s. See \"Server ID\" in the chart README." uuidv4 (include "bridgelink.legacyServerId" .)) -}}
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
