# syntax=docker/dockerfile:1

# AgentCore Runtime only runs linux/arm64 images -- always build with
# `docker buildx build --platform linux/arm64`.

FROM ballerina/ballerina:2201.13.5 AS build
WORKDIR /home/ballerina/mcp-server
COPY --chown=ballerina:ballerina Ballerina.toml Dependencies.toml ./
COPY --chown=ballerina:ballerina *.bal ./
RUN bal build

FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=build /home/ballerina/mcp-server/target/bin/tools_mcp_server.jar /app/mcp-server.jar

# OpenTelemetry Collector (contrib), copied in as a single static binary, exactly as the
# agent does it. AgentCore Runtime gives you one container rather than a pod, so this
# runs as a second process rather than a sidecar. See `start.sh`.
#
# Without it this runtime produces only the platform's own `AgentCore.Runtime.Invoke`
# span: you can see that the server was called and how long it took, but not which tool
# ran, with what arguments, or what it returned.
COPY --from=otel/opentelemetry-collector-contrib:latest \
     /otelcol-contrib /usr/local/bin/otelcol
COPY otel-collector.yaml /etc/otel/config.yaml
COPY start.sh /app/start.sh

# Ballerina reads `Config.toml` from the working directory. This one holds only tracing
# settings; this runtime is given no secrets at all.
COPY observability.toml /app/Config.toml
RUN chmod +x /app/start.sh /usr/local/bin/otelcol

# The MCP protocol contract is port 8000, not the 8080 the HTTP contract uses.
# mcp:StreamableHttpListener binds 0.0.0.0 by default, which the contract requires.
EXPOSE 8000
ENTRYPOINT ["/app/start.sh"]
