#!/bin/sh
# Two processes in one container: AgentCore Runtime gives you a container, not a pod,
# so the collector cannot be a sidecar.
#
# The collector goes to the background and the agent runs in the foreground, because
# the container's lifecycle must follow the agent -- AgentCore health-checks it on
# :8080, and an agent that dies has to take the container with it. A dead collector
# only costs traces.
set -e

/usr/local/bin/awscollector --config=/etc/otel/config.yaml &

exec java -jar /app/agent.jar
