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

# The Ballerina http:Listener binds 0.0.0.0 by default, which the contract requires.
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/agent.jar"]
