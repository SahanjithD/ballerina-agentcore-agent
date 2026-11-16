# syntax=docker/dockerfile:1

# AgentCore Runtime only runs linux/arm64 images -- always build with
# `docker buildx build --platform linux/arm64`.

FROM ballerina/ballerina:2201.14.1 AS build
WORKDIR /home/ballerina/agent
COPY --chown=ballerina:ballerina Ballerina.toml Dependencies.toml ./
COPY --chown=ballerina:ballerina *.bal ./
RUN bal build

FROM eclipse-temurin:25-jre-jammy
WORKDIR /app
COPY --from=build /home/ballerina/agent/target/bin/ballerina_agent.jar /app/agent.jar

# OpenTelemetry Collector (contrib), copied in as a single static binary. AgentCore
# Runtime gives you one container rather than a pod, so this cannot be a sidecar -- it
# runs as a second process. See `start.sh`.
#
# Contrib rather than AWS's own ADOT distro: ADOT v0.50.0 does not ship the `transform`
# processor (verified -- it is absent from the error message listing valid processors),
# and OTTL is the only way to compute `gen_ai.usage.total_tokens` from the separate
# input/output counts Ballerina emits. Contrib ships both `transform` and the
# `sigv4auth` extension the X-Ray OTLP endpoint requires, and publishes arm64.
COPY --from=otel/opentelemetry-collector-contrib:0.161.0 \
     /otelcol-contrib /usr/local/bin/otelcol
COPY otel-collector.yaml /etc/otel/config.yaml
COPY start.sh /app/start.sh

# Ballerina reads `Config.toml` from the working directory. The repo's own
# Config.toml is for local runs and is deliberately not copied; this one carries only
# the tracing settings, which are not secret and cannot be passed as
# `BAL_CONFIG_VAR_*`. The Gateway client credentials arrive as environment variables,
# and the two sources merge rather than conflict.
COPY observability.toml /app/Config.toml
RUN chmod +x /app/start.sh /usr/local/bin/otelcol

# The Ballerina http:Listener binds 0.0.0.0 by default, which the contract requires.
EXPOSE 8080
ENTRYPOINT ["/app/start.sh"]
