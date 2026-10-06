# shellcheck shell=bash
#
# BridgeLink REST API helpers shared by the chart tests (kind-test.sh, eks/eks-test.sh). Sourced,
# never run. The caller sets:
#   WORK              a scratch directory (cookies, port-forward log)
#   BL_NS             the namespace forward() uses when none is given
#   BL_KUBE_CONTEXT   optional kubectl context; empty uses the current one (KUBECONFIG)
#   CHANNEL_ID, MSG_ID, MARKER   read by message_readable()
#   BL_SELECTOR, TIMEOUT         read by replace_pod()

bl_kubectl() { kubectl ${BL_KUBE_CONTEXT:+--context "$BL_KUBE_CONTEXT"} "$@"; }

# The BridgeLink Service of a release, named as the chart's fullname helper names it: the release
# name alone when it already contains "bridgelink", otherwise <release>-bridgelink.
bl_service() { case "$1" in *bridgelink*) echo "$1-bl" ;; *) echo "$1-bridgelink-bl" ;; esac; }

# ---- BridgeLink REST API, through a port-forward to the release's Service ----------------------
# A port-forward follows one pod, so it is restarted after every pod replacement.
forward() {   # <release> [namespace]; sets API
  local port=""
  [ -n "${PF_PID:-}" ] && { kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null; }
  bl_kubectl -n "${2:-$BL_NS}" port-forward "svc/$(bl_service "$1")" :8443 > "$WORK/pf.log" 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 30); do
    port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$WORK/pf.log" | head -1)"
    [ -n "$port" ] && break
    sleep 1
  done
  API="https://127.0.0.1:${port:-0}/api"
}
api() {       # <method> <path> [curl args...]; the API rejects requests without X-Requested-With
  local method="$1" path="$2"; shift 2
  curl -sk -m 60 -b "$WORK/cookies" -c "$WORK/cookies" -H 'X-Requested-With: chart-test' \
    -X "$method" "$API$path" "$@"
}
login() {     # prints the HTTP status; admin/admin works on a fresh install
  rm -f "$WORK/cookies"
  api POST /users/_login --data-urlencode username=admin --data-urlencode password=admin \
    -o /dev/null -w '%{http_code}'
}

# A channel that stores every message with encryption on. RAW in and out, so a message needs no
# parsing. Shape from bridgelink-mcp's create_channel skeleton. The source is a Channel Reader, an
# HTTP Listener when a port is given, or a TCP Listener in MLLP mode when the kind is "mllp". The
# listeners need every field their constructors would set: the server fills omitted ones with
# null, and the deploy then fails (the HTTP Listener on a null binaryMimeTypes).
channel_json() {   # <server version> <channel id> <name> [listener port] [http|mllp]
  local v="$1" id="$2" name="$3" port="${4:-}" kind="${5:-http}" transport props
  local rid='{"@class":"linked-hash-map","entry":{"string":["Default Resource","[Default Resource]"]}}'
  local raw='{"@class":"com.mirth.connect.plugins.datatypes.raw.RawDataTypeProperties","@version":"'"$v"'","batchProperties":{"@class":"com.mirth.connect.plugins.datatypes.raw.RawBatchProperties","@version":"'"$v"'","splitType":"JavaScript","batchScript":""}}'
  local scp='{"@version":"'"$v"'","responseVariable":"None","respondAfterProcessing":true,"processBatch":false,"firstResponse":false,"processingThreads":1,"resourceIds":'"$rid"',"queueBufferSize":1000}'
  if [ -n "$port" ] && [ "$kind" = "mllp" ]; then
    # TcpReceiverProperties' constructor defaults, with the MLLP frame (0B ... 1C0D) the
    # Administrator's TCP Listener starts with.
    transport="TCP Listener"
    props='{"@class":"com.mirth.connect.connectors.tcp.TcpReceiverProperties","@version":"'"$v"'","pluginProperties":null,
   "listenerConnectorProperties":{"@version":"'"$v"'","host":"0.0.0.0","port":"'"$port"'"},"sourceConnectorProperties":'"$scp"',
   "transmissionModeProperties":{"@class":"com.mirth.connect.plugins.mllpmode.MLLPModeProperties","pluginPointName":"MLLP",
    "startOfMessageBytes":"0B","endOfMessageBytes":"1C0D","useMLLPv2":false,"ackBytes":"06","nackBytes":"15","maxRetries":"2"},
   "serverMode":true,"remoteAddress":"","remotePort":"","overrideLocalBinding":false,"reconnectInterval":"5000",
   "receiveTimeout":"0","bufferSize":"65536","maxConnections":"10","keepConnectionOpen":true,"dataTypeBinary":false,
   "charsetEncoding":"DEFAULT_ENCODING","respondOnNewConnection":0,"responseAddress":"","responsePort":"",
   "responseConnectorPluginProperties":null}'
  elif [ -n "$port" ]; then
    transport="HTTP Listener"
    props='{"@class":"com.mirth.connect.connectors.http.HttpReceiverProperties","@version":"'"$v"'","pluginProperties":null,
   "listenerConnectorProperties":{"@version":"'"$v"'","host":"0.0.0.0","port":"'"$port"'"},"sourceConnectorProperties":'"$scp"',
   "xmlBody":false,"parseMultipart":false,"includeMetadata":false,"binaryMimeTypes":"application/, image/, video/, audio/",
   "binaryMimeTypesRegex":false,"responseContentType":"text/plain","responseDataTypeBinary":false,"responseStatusCode":"",
   "responseHeaders":{"@class":"linked-hash-map"},"responseHeadersVariable":"","useResponseHeadersVariable":false,
   "charset":"UTF-8","contextPath":"","timeout":"30000","staticResources":null}'
  else
    transport="Channel Reader"
    props='{"@class":"com.mirth.connect.connectors.vm.VmReceiverProperties","@version":"'"$v"'","pluginProperties":null,"sourceConnectorProperties":'"$scp"'}'
  fi
  cat <<EOF
{"channel":{"@version":"$v","id":"$id","nextMetaDataId":2,"name":"$name","description":"","revision":1,
 "sourceConnector":{"@version":"$v","metaDataId":0,"name":"sourceConnector",
  "properties":$props,
  "transformer":{"@version":"$v","elements":null,"inboundTemplate":{"@encoding":"base64"},"outboundTemplate":{"@encoding":"base64"},"inboundDataType":"RAW","outboundDataType":"RAW","inboundProperties":$raw,"outboundProperties":$raw},
  "filter":{"@version":"$v","elements":null},"transportName":"$transport","mode":"SOURCE","enabled":true,"waitForPrevious":true},
 "destinationConnectors":{"connector":{"@version":"$v","metaDataId":1,"name":"Destination 1",
  "properties":{"@class":"com.mirth.connect.connectors.vm.VmDispatcherProperties","@version":"$v","pluginProperties":null,
   "destinationConnectorProperties":{"@version":"$v","queueEnabled":false,"sendFirst":false,"retryIntervalMillis":10000,"regenerateTemplate":false,"retryCount":0,"rotate":false,"includeFilterTransformer":false,"threadCount":1,"threadAssignmentVariable":null,"validateResponse":false,"resourceIds":$rid,"queueBufferSize":1000,"reattachAttachments":true},
   "channelId":"none","channelTemplate":"\${message.encodedData}","mapVariables":null},
  "transformer":{"@version":"$v","elements":null,"inboundDataType":"RAW","outboundDataType":"RAW","inboundProperties":$raw,"outboundProperties":$raw},
  "responseTransformer":{"@version":"$v","elements":null,"inboundDataType":"RAW","outboundDataType":"RAW","inboundProperties":$raw,"outboundProperties":$raw},
  "filter":{"@version":"$v","elements":null},"transportName":"Channel Writer","mode":"DESTINATION","enabled":true,"waitForPrevious":true}},
 "preprocessingScript":"return message;","postprocessingScript":"return;","deployScript":"return;","undeployScript":"return;",
 "properties":{"@version":"$v","clearGlobalChannelMap":true,"messageStorageMode":"DEVELOPMENT","encryptData":true,"encryptAttachments":false,"encryptCustomMetaData":false,
  "removeContentOnCompletion":false,"removeOnlyFilteredOnCompletion":false,"removeAttachmentsOnCompletion":false,"initialState":"STARTED","storeAttachments":true,
  "metaDataColumns":null,"attachmentProperties":{"@version":"$v","type":"None","properties":null},"resourceIds":$rid},
 "exportData":{"metadata":{"enabled":true,"pruningSettings":{"archiveEnabled":true,"pruneErroredMessages":false}},"dependentIds":null,"dependencyIds":null,"channelTags":null}}}
EOF
}

# Prints 1 if the stored message comes back decrypted (its content contains MARKER), else 0.
message_readable() {
  api GET "/channels/$CHANNEL_ID/messages/$MSG_ID" -H 'Accept: application/json' | grep -c "$MARKER"
}

# Deletes the BridgeLink pod matching BL_SELECTOR in BL_NS and waits for its replacement to be
# Ready. Prints "<old> -> <new>", or nothing if no replacement became Ready.
replace_pod() {
  local old new=""
  old="$(bl_kubectl -n "$BL_NS" get pods -l "$BL_SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
  bl_kubectl -n "$BL_NS" delete pod "$old" --wait=true --timeout=3m >/dev/null
  for _ in $(seq 1 60); do
    new="$(bl_kubectl -n "$BL_NS" get pods -l "$BL_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    [ -n "$new" ] && [ "$new" != "$old" ] && break
    sleep 2
  done
  [ -n "$new" ] && bl_kubectl -n "$BL_NS" wait --for=condition=Ready "pod/$new" --timeout="$TIMEOUT" >/dev/null \
    && echo "$old -> $new"
}
