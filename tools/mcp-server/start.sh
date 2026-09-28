#!/bin/sh
# Two processes in one container, same shape as the agent's start.sh: AgentCore Runtime
# gives you a container rather than a pod, so the collector cannot be a sidecar.
#
# The collector goes to the background and the MCP server runs in the foreground, so the
# container's lifecycle follows the server. A dead collector only costs traces.
set -e

CONFIG=/etc/otel/config.yaml

# AgentCore injects OTEL_RESOURCE_ATTRIBUTES with exactly the identity CloudWatch
# expects. Reading it beats hand-building these values -- `cloud.resource_id` in
# particular is an endpoint ARN with the endpoint name appended, not the runtime ARN.
otel_attr() {
    printf '%s' "$OTEL_RESOURCE_ATTRIBUTES" | tr ',' '\n' | sed -n "s/^$1=//p" | head -1
}

AGENT_SERVICE_NAME=$(otel_attr 'service\.name')
AGENT_CLOUD_RESOURCE_ID=$(otel_attr 'cloud\.resource_id')
AGENT_DEPLOYMENT_ENV=$(otel_attr 'deployment\.environment\.name')
AGENT_LOG_GROUP=$(otel_attr 'aws\.log\.group\.names')
AGENT_LOG_STREAM=$(otel_attr 'aws\.log\.stream\.names')
AGENT_CLOUD_PLATFORM=$(otel_attr 'cloud\.platform')
AGENT_CLOUD_PROVIDER=$(otel_attr 'cloud\.provider')
AGENT_CLOUD_REGION=$(otel_attr 'cloud\.region')
export AGENT_SERVICE_NAME AGENT_CLOUD_RESOURCE_ID AGENT_DEPLOYMENT_ENV \
    AGENT_LOG_GROUP AGENT_LOG_STREAM AGENT_CLOUD_PLATFORM AGENT_CLOUD_PROVIDER \
    AGENT_CLOUD_REGION

# The collector exits 1 if any ${env:...} resolves to an empty string, and being
# backgrounded that failure would be silent: the server would serve tools normally and
# emit nothing. Drop the processors rather than let the collector die.
if [ -z "$AGENT_SERVICE_NAME" ] || [ -z "$AGENT_CLOUD_RESOURCE_ID" ] ||
    [ -z "$AGENT_DEPLOYMENT_ENV" ] || [ -z "$AGENT_LOG_GROUP" ] ||
    [ -z "$AGENT_LOG_STREAM" ] || [ -z "$AGENT_CLOUD_PLATFORM" ] ||
    [ -z "$AGENT_CLOUD_PROVIDER" ] || [ -z "$AGENT_CLOUD_REGION" ]; then
    echo "start.sh: OTEL_RESOURCE_ATTRIBUTES missing or incomplete -- tracing without AgentCore resource identity" >&2
    sed -e 's|, resource/agent_identity||' -e 's|, attributes/agentcore_origin||' \
        "$CONFIG" > /tmp/otel-config.yaml
    CONFIG=/tmp/otel-config.yaml
fi

/usr/local/bin/otelcol --config="$CONFIG" &

exec java -jar /app/mcp-server.jar
