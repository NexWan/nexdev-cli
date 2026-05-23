import { stderr, stdin, stdout } from "node:process";
import { createInterface } from "node:readline";
import { Codex } from "@openai/codex-sdk";
import { buildAgent } from "./agents.ts";

type JsonRpcId = string | number | null;
type JsonObject = Record<string, unknown>;

const codex = new Codex();
const systemInstruction =
  "You are the NexDev CLI assistant. Answer the user's latest message directly and keep responses concise unless the user asks for implementation detail.";

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sendJson(value: unknown): void {
  stdout.write(`${JSON.stringify(value)}\n`);
}

function sendError(id: JsonRpcId, code: number, message: string): void {
  sendJson({
    jsonrpc: "2.0",
    error: { code, message },
    id,
  });
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function requestId(message: JsonObject): JsonRpcId {
  const id = message.id;
  if (typeof id === "string" || typeof id === "number" || id === null) {
    return id;
  }
  return null;
}

function latestUserMessage(messages: unknown): string {
  if (!Array.isArray(messages)) return "";

  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const item = messages[index];
    if (!isObject(item)) continue;
    if (item.role !== "user") continue;
    return typeof item.content === "string" ? item.content : "";
  }

  return "";
}

function stringParam(params: JsonObject, key: string): string | undefined {
  const value = params[key];
  return typeof value === "string" ? value : undefined;
}

function formatTranscript(messages: unknown): string {
  if (!Array.isArray(messages)) return "";

  const rows: string[] = [];
  for (const item of messages) {
    if (!isObject(item)) continue;
    if (typeof item.role !== "string") continue;
    if (typeof item.content !== "string") continue;
    rows.push(`${item.role}: ${item.content}`);
  }

  return rows.join("\n\n");
}

function buildPrompt(text: string, messages: unknown): string {
  const transcript = formatTranscript(messages);
  if (transcript.length > 0) {
    return `Conversation so far:\n${transcript}\n\nReply to the latest user message.`;
  }

  return `Reply to the latest user message in this chat.\n\nLatest user message:\n${text}`;
}

async function handleMessage(message: JsonObject): Promise<void> {
  const id = requestId(message);

  if (message.method !== "message.received") {
    sendError(id, -32601, "Method not found");
    return;
  }

  if (!isObject(message.params)) {
    sendError(id, -32602, "Invalid params");
    return;
  }

  const params = message.params;
  const messages = Array.isArray(params.messages) ? params.messages : [];
  const text =
    typeof params.text === "string" ? params.text : latestUserMessage(messages);

  stderr.write(`received from zig: ${JSON.stringify(message)}\n`);

  const agent = buildAgent({
    codex,
    model: stringParam(params, "model"),
    reasoningEffort:
      stringParam(params, "reasoningEffort") ??
      stringParam(params, "reasoning_effort"),
    workspaceDir: process.cwd(),
    systemInstruction,
    skipGitRepoCheck: true,
  });

  const turn = await agent.run(buildPrompt(text, messages));

  sendJson({
    jsonrpc: "2.0",
    id,
    result: turn.finalResponse,
  });
}

const lines = createInterface({ input: stdin, crlfDelay: Infinity });

for await (const line of lines) {
  if (line.trim().length === 0) continue;

  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    sendError(null, -32700, "Parse error");
    continue;
  }

  if (!isObject(parsed)) {
    sendError(null, -32600, "Invalid Request");
    continue;
  }

  try {
    await handleMessage(parsed);
  } catch (error) {
    sendError(requestId(parsed), -32000, errorMessage(error));
  }
}
