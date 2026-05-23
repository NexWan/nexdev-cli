import {
  Codex,
  type CodexOptions,
  type Input,
  type ModelReasoningEffort,
  type RunResult,
  type RunStreamedResult,
  type Thread,
  type ThreadOptions,
  type TurnOptions,
} from "@openai/codex-sdk";

export type ReasoningEffort = ModelReasoningEffort;

export type BaseAgent = {
  model?: string;
  reasoningEffort?: string;
  workspaceDir?: string;
  systemInstruction?: string;
  skipGitRepoCheck?: boolean;
  threadId?: string;
  codex?: Codex;
  codexOptions?: CodexOptions;
  threadOptions?: ThreadOptions;
};

export type BuiltAgent = {
  readonly thread: Thread;
  readonly config: ThreadOptions;
  readonly id: string | null;
  run(input: Input, turnOptions?: TurnOptions): Promise<RunResult>;
  runStreamed(
    input: Input,
    turnOptions?: TurnOptions,
  ): Promise<RunStreamedResult>;
};

const modelAliases: Record<string, string> = {
  "gpt-5.5": "gpt-5.5",
  "gpt-5.4": "gpt-5.4",
  "gpt-5.4 mini": "gpt-5.4-mini",
  "gpt-5.3 codex": "gpt-5.3-codex",
};

const reasoningEfforts: ModelReasoningEffort[] = [
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
];

export function buildAgent(parameters: BaseAgent = {}): BuiltAgent {
  const codex = parameters.codex ?? new Codex(parameters.codexOptions);
  const config = buildThreadOptions(parameters);
  const thread = parameters.threadId
    ? codex.resumeThread(parameters.threadId, config)
    : codex.startThread(config);

  return {
    thread,
    config,
    get id() {
      return thread.id;
    },
    run(input: Input, turnOptions?: TurnOptions) {
      return thread.run(
        applySystemInstruction(input, parameters.systemInstruction),
        turnOptions,
      );
    },
    runStreamed(input: Input, turnOptions?: TurnOptions) {
      return thread.runStreamed(
        applySystemInstruction(input, parameters.systemInstruction),
        turnOptions,
      );
    },
  };
}

export function buildThreadOptions(parameters: BaseAgent): ThreadOptions {
  const options: ThreadOptions = { ...(parameters.threadOptions ?? {}) };
  const model = normalizeModel(parameters.model);
  const reasoningEffort = normalizeReasoningEffort(parameters.reasoningEffort);
  const workspaceDir = normalizedNonEmpty(parameters.workspaceDir);

  if (model) {
    options.model = model;
  }
  if (reasoningEffort) {
    options.modelReasoningEffort = reasoningEffort;
  }
  if (workspaceDir) {
    options.workingDirectory = workspaceDir;
  }
  if (parameters.skipGitRepoCheck !== undefined) {
    options.skipGitRepoCheck = parameters.skipGitRepoCheck;
  }

  return options;
}

export function normalizeModel(model: string | undefined): string | undefined {
  const normalized = normalizedNonEmpty(model);
  if (!normalized) return undefined;

  return modelAliases[normalized.toLowerCase()] ?? normalized;
}

export function normalizeReasoningEffort(
  reasoningEffort: string | undefined,
): ModelReasoningEffort | undefined {
  const normalized = normalizedNonEmpty(reasoningEffort)?.toLowerCase();
  if (!normalized) return undefined;

  if (isReasoningEffort(normalized)) {
    return normalized;
  }

  throw new Error(`Unsupported reasoning effort: ${reasoningEffort}`);
}

export function applySystemInstruction(
  input: Input,
  systemInstruction: string | undefined,
): Input {
  const instruction = normalizedNonEmpty(systemInstruction);
  if (!instruction) return input;

  const prefix = `System instructions:\n${instruction}`;
  if (typeof input === "string") {
    return `${prefix}\n\nUser request:\n${input}`;
  }

  return [{ type: "text", text: prefix }, ...input];
}

function normalizedNonEmpty(value: string | undefined): string | undefined {
  const normalized = value?.trim();
  return normalized && normalized.length > 0 ? normalized : undefined;
}

function isReasoningEffort(value: string): value is ModelReasoningEffort {
  return reasoningEfforts.includes(value as ModelReasoningEffort);
}
