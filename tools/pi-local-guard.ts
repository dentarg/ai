import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const MAX_GEMMA_TOOL_CALLS = 24;
const MAX_QWEN_TOOL_CALLS = 16;
const MAX_QWEN_INSPECTION_CALLS = 6;
const MAX_CONSECUTIVE_TOOL_ERRORS = 3;
const MAX_READ_LINES = 200;
const INSPECTION_TOOLS = new Set(["bash", "find", "grep", "ls", "read"]);

const TOOL_GUIDANCE = `## Local model guardrails

- Never run recursive directory listings. Use \`rg --files\` with explicit
  exclusions such as \`-g '!node_modules'\` and inspect only relevant paths.
- Do not use \`find\` without either \`-maxdepth\` or an explicit pruning rule.
- Copy paths exactly from tool output. After a tool error, inspect the error and
  change approach instead of retrying variants of the same call.
- Read at most 200 lines at a time. Begin editing within six inspection calls;
  do not exhaustively map the repository before making the first change.
- Keep the task bounded. Make the smallest relevant change, run its focused
  test, and report completion.`;

type MessageLike = {
	role?: string;
	content?: unknown;
};

function truncate(text: string, length: number): string {
	const normalized = text.replace(/\s+/g, " ").trim();
	return normalized.length <= length ? normalized : `${normalized.slice(0, length - 1)}…`;
}

function contentText(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";

	return content
		.map((block) => {
			if (typeof block !== "object" || block === null) return "";
			const value = block as Record<string, unknown>;
			if (typeof value.text === "string") return value.text;
			return typeof value.thinking === "string" ? value.thinking : "";
		})
		.filter(Boolean)
		.join("\n");
}

function formatPaths(paths: string[]): string {
	const shown = paths.slice(0, 20);
	const remainder = paths.length - shown.length;
	return `${shown.join(", ")}${remainder > 0 ? `, and ${remainder} more` : ""}` || "none";
}

function isRecursiveListing(command: string): boolean {
	const words = command.split(/\s+/);

	for (let index = 0; index < words.length; index += 1) {
		const word = words[index].replace(/^[;&|()]+|[;&|()]+$/g, "");
		if (word === "ls") {
			for (let optionIndex = index + 1; optionIndex < words.length; optionIndex += 1) {
				const option = words[optionIndex].replace(/[;&|()]+$/g, "");
				if (/^[;&|]/.test(words[optionIndex])) break;
				if (option === "--recursive" || /^-[A-Za-z]*R[A-Za-z]*$/.test(option)) return true;
			}
		}
	}

	if (!words.some((word) => word.replace(/^[;&|()]+|[;&|()]+$/g, "") === "find")) return false;

	return !words.includes("-maxdepth") && !words.includes("-prune");
}

export default function (pi: ExtensionAPI) {
	let consecutiveToolErrors = 0;
	let inspectionCalls = 0;
	let qwenModifiedFiles = false;
	let toolCalls = 0;

	pi.on("agent_start", () => {
		consecutiveToolErrors = 0;
		inspectionCalls = 0;
		qwenModifiedFiles = false;
		toolCalls = 0;
	});

	pi.on("before_agent_start", (event) => ({
		systemPrompt: `${event.systemPrompt}\n\n${TOOL_GUIDANCE}`,
	}));

	pi.on("before_provider_request", (event, ctx) => {
		if (ctx.model?.id !== "gemma4") return;
		if (typeof event.payload !== "object" || event.payload === null) return;

		return {
			...event.payload,
			chat_template_kwargs: {
				...((event.payload as Record<string, unknown>).chat_template_kwargs as object | undefined),
				enable_thinking: true,
				preserve_thinking: true,
			},
		};
	});

	pi.on("session_before_compact", (event, ctx) => {
		if (ctx.model?.id !== "qwen38") return;

		const { preparation } = event;
		const userMessages = event.branchEntries
			.filter((entry) => entry.type === "message")
			.map((entry) => (entry as { message: MessageLike }).message)
			.filter((message) => message.role === "user")
			.map((message) => contentText(message.content))
			.filter(Boolean);
		const userContext = userMessages.length > 1
			? `${userMessages[0]}\nLatest request: ${userMessages[userMessages.length - 1]}`
			: userMessages[0];
		const task = truncate(userContext || preparation.previousSummary || "Continue the current task.", 1200);
		const compactedMessages = [
			...preparation.messagesToSummarize,
			...preparation.turnPrefixMessages,
		] as MessageLike[];
		const latestReasoning = compactedMessages
			.slice()
			.reverse()
			.filter((message) => message.role === "assistant")
			.map((message) => contentText(message.content))
			.find(Boolean);
		const modifiedFiles = [...new Set([
			...preparation.fileOps.written,
			...preparation.fileOps.edited,
		])].sort();
		const readFiles = [...preparation.fileOps.read]
			.filter((path) => !modifiedFiles.includes(path))
			.sort();
		const reasoning = latestReasoning
			? `\n\n## Latest reasoning\n${truncate(latestReasoning, 1500)}`
			: "";
		const summary = `## Task
${task}

## State
Context was compacted after bounded inspection. Recent messages remain in
context. Do not repeat completed searches; continue with an edit and focused
test.${reasoning}

## Files
Read: ${truncate(formatPaths(readFiles), 800)}
Modified: ${truncate(formatPaths(modifiedFiles), 800)}`;

		return {
			compaction: {
				summary,
				firstKeptEntryId: preparation.firstKeptEntryId,
				tokensBefore: preparation.tokensBefore,
				details: { readFiles, modifiedFiles },
			},
		};
	});

	pi.on("tool_call", (event, ctx) => {
		if (consecutiveToolErrors >= MAX_CONSECUTIVE_TOOL_ERRORS) {
			return {
				block: true,
				reason: "Stopped after 3 consecutive tool errors; review the errors before continuing.",
				terminate: true,
			};
		}

		const toolLimit = ctx.model?.id === "qwen38"
			? MAX_QWEN_TOOL_CALLS
			: ctx.model?.id === "gemma4" ? MAX_GEMMA_TOOL_CALLS : undefined;
		if (toolLimit !== undefined && toolCalls >= toolLimit) {
			return {
				block: true,
				reason: `Stopped after ${ctx.model?.id} reached its ${toolLimit}-call task limit.`,
				terminate: true,
			};
		}

		toolCalls += 1;
		if (event.toolName === "edit" || event.toolName === "write") return;

		if (event.toolName === "read" &&
			(typeof event.input.limit !== "number" || event.input.limit > MAX_READ_LINES)) {
			return {
				block: true,
				reason: "Read blocked; specify a limit of at most 200 lines.",
			};
		}

		if (event.toolName === "bash") {
			const command = event.input.command;
			if (typeof command === "string" && isRecursiveListing(command)) {
				return {
					block: true,
					reason: "Recursive listing blocked; use rg --files with explicit exclusions.",
				};
			}
		}

		if (ctx.model?.id === "qwen38" && !qwenModifiedFiles && INSPECTION_TOOLS.has(event.toolName)) {
			if (inspectionCalls >= MAX_QWEN_INSPECTION_CALLS) {
				return {
					block: true,
					reason: "Qwen inspection budget exhausted; make the first edit before inspecting more.",
				};
			}
			inspectionCalls += 1;
		}
	});

	pi.on("tool_result", (event) => {
		consecutiveToolErrors = event.isError ? consecutiveToolErrors + 1 : 0;
		if (!event.isError && (event.toolName === "edit" || event.toolName === "write")) {
			qwenModifiedFiles = true;
		}
	});
}
