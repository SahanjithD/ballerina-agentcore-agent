# syntax=docker/dockerfile:1

# AgentCore Runtime only runs linux/arm64 images -- always build with
# `docker buildx build --platform linux/arm64`.

FROM ballerina/ballerina:2201.13.5 AS build
WORKDIR /home/ballerina/agent
COPY --chown=ballerina:ballerina Ballerina.toml Dependencies.toml ./
COPY --chown=ballerina:ballerina *.bal ./
RUN bal build

FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=build /home/ballerina/agent/target/bin/ballerina_agent.jar /app/agent.jar

# AWS Distro for OpenTelemetry Collector, copied in as a single static binary.
# AgentCore Runtime gives you one container rather than a pod, so this cannot be a
# sidecar -- it runs as a second process. See `start.sh`.
COPY --from=public.ecr.aws/aws-observability/aws-otel-collector:latest \
     /awscollector /usr/local/bin/awscollector
COPY otel-collector.yaml /etc/otel/config.yaml
COPY start.sh /app/start.sh

# Ballerina reads `Config.toml` from the working directory. The repo's own
# Config.toml holds the Anthropic key and is deliberately not copied; this one
# carries only the tracing settings, which are not secret and cannot be passed as
# `BAL_CONFIG_VAR_*`. The API key still arrives as an environment variable, and the
# two sources merge rather than conflict.
COPY observability.toml /app/Config.toml
RUN chmod +x /app/start.sh /usr/local/bin/awscollector

# The Ballerina http:Listener binds 0.0.0.0 by default, which the contract requires.
EXPOSE 8080
ENTRYPOINT ["/app/start.sh"]
