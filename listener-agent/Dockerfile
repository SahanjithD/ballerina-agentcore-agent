# syntax=docker/dockerfile:1

# The agentcore:Listener variant of the agent. It reuses the repo's tracing files
# (start.sh, otel-collector.yaml, observability.toml), so the build context is the repo
# root. The jar is built on the host, because the listener comes from the local
# Ballerina repository, which the ballerina/ballerina image does not have:
#
#   (cd listener-agent && bal build)
#   docker buildx build --platform linux/arm64 -f listener-agent/Dockerfile -t <image> .
#
# AgentCore Runtime only runs linux/arm64 images.

FROM eclipse-temurin:25-jre-jammy
WORKDIR /app
COPY listener-agent/target/bin/ballerina_agent_listener.jar /app/agent.jar

# OpenTelemetry Collector (contrib), run as a second process by start.sh. See the root
# Dockerfile for why contrib and not ADOT.
COPY --from=otel/opentelemetry-collector-contrib:0.161.0 \
     /otelcol-contrib /usr/local/bin/otelcol
COPY otel-collector.yaml /etc/otel/config.yaml
COPY start.sh /app/start.sh

# Tracing settings only; nothing secret. No local Config.toml is copied: configuration
# (gatewayCredentialProvider and the rest) arrives as BAL_CONFIG_VAR_* environment variables.
COPY observability.toml /app/Config.toml
RUN chmod +x /app/start.sh /usr/local/bin/otelcol

# agentcore:Listener binds 0.0.0.0:8080, as the contract requires.
EXPOSE 8080
ENTRYPOINT ["/app/start.sh"]
