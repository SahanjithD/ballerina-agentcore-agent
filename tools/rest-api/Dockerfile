# syntax=docker/dockerfile:1

# Lambda runs this as a container image on arm64 -- build with
# `docker buildx build --platform linux/arm64`.

FROM ballerina/ballerina:2201.13.5 AS build
WORKDIR /home/ballerina/rest-api
COPY --chown=ballerina:ballerina Ballerina.toml Dependencies.toml ./
COPY --chown=ballerina:ballerina *.bal ./
RUN bal build

FROM eclipse-temurin:21-jre-jammy

# The Lambda Web Adapter is an external extension, not a base image: Lambda starts
# the ENTRYPOINT below as the process, and the adapter bridges the Lambda Runtime API
# to a plain HTTP server on AWS_LWA_PORT. That is what lets an unmodified Ballerina
# http:Listener serve a Function URL with no Lambda-specific code in the service.
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.0.1 /lambda-adapter /opt/extensions/lambda-adapter

# Point the adapter's readiness probe at the service's own health resource so a cold
# JVM is never handed a real request before the listener is up.
ENV AWS_LWA_PORT=8080
ENV AWS_LWA_READINESS_CHECK_PATH=/v1/health

WORKDIR /app
COPY --from=build /home/ballerina/rest-api/target/bin/tools_rest_api.jar /app/rest-api.jar
ENTRYPOINT ["java", "-jar", "/app/rest-api.jar"]
