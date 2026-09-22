#!/bin/sh
# Two processes in one container: AgentCore Runtime gives you a container, not a pod,
# so the collector cannot be a sidecar.
#
# The collector goes to the background and the agent runs in the foreground, because
# the container's lifecycle must follow the agent -- AgentCore health-checks it on
# :8080, and an agent that dies has to take the container with it. A dead collector
# only costs traces.
set -e

CONFIG=/etc/otel/config.yaml

# AgentCore injects OTEL_RESOURCE_ATTRIBUTES into the container with exactly the
# identity CloudWatch expects, e.g.
#
#   service.name=ballerina_agent.DEFAULT
#   cloud.resource_id=arn:...:runtime/<id>/runtime-endpoint/DEFAULT:DEFAULT
#   deployment.environment.name=bedrock-agentcore:default
#
# Reading it beats hand-building these values. The `cloud.resource_id` form is an
# endpoint ARN with the endpoint name appended -- not the runtime ARN, which is what
# we assumed at first and why spans were landing as PlatformType: Generic with the
# agent dashboard unable to roll up their token counts. The format is AWS's to
# change, so take it from AWS rather than reconstructing it.
#
# Outside AgentCore nothing injects this, and OTEL_RESOURCE_ATTRIBUTES is the
# standard OpenTelemetry variable anyway -- set it yourself and this works unchanged.
otel_attr() {
    printf '%s' "$OTEL_RESOURCE_ATTRIBUTES" | tr ',' '\n' | sed -n "s/^$1=//p" | head -1
}

# NOTE: `aws.log.group.names` is plural and OTel encodes lists comma-separated --
# the same character that separates attributes. With the single log group AgentCore
# sets today this parses correctly; several would need a smarter split.
#
# This list must mirror everything AgentCore injects. Setting only a subset is worse
# than setting none: the attributes left out are simply absent from the spans, which
# is how `cloud.platform` and `cloud.provider` were lost when this was first written
# against five of the eight.
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

# The collector exits 1 if any ${env:...} in `resource/agent_identity` resolves to an
# empty string -- verified: "Either field value, from_attribute, from_context, or
# default_value must be specified". Backgrounded as it is, that failure would be
# silent: the agent would serve traffic normally and emit no traces at all. So when
# the identity is not available, drop the processor rather than let the collector die.
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

exec java -jar /app/agent.jar
