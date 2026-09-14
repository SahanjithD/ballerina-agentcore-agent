import ballerina/ai;
import ballerinax/ai.anthropic;

configurable string anthropicApiKey = ?;
configurable anthropic:ANTHROPIC_MODEL_NAMES modelType = anthropic:CLAUDE_OPUS_4_6;

@ai:AgentTool
isolated function sum(int a, int b) returns int => a + b;

@ai:AgentTool
isolated function multiply(int a, int b) returns int => a * b;

final ai:ModelProvider claudeModel = check new anthropic:ModelProvider(anthropicApiKey, modelType);

final ai:Agent assistantAgent = check new (
    systemPrompt = {
        role: "Assistant",
        instructions: "You are a helpful assistant. Use the provided tools when they help answer the question."
    },
    model = claudeModel,
    tools = [sum, multiply]
);
