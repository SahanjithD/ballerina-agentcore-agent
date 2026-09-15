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

# The MCP protocol contract is port 8000, not the 8080 the HTTP contract uses.
# mcp:StreamableHttpListener binds 0.0.0.0 by default, which the contract requires.
EXPOSE 8000
ENTRYPOINT ["java", "-jar", "/app/mcp-server.jar"]
