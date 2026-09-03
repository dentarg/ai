import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const MAX_GEMMA_TOOL_CALLS = 24;
const MAX_CONSECUTIVE_TOOL_ERRORS = 3;

const TOOL_GUIDANCE = `## Local model guardrails

- Never run recursive directory listings. Use \`rg --files\` with explicit
  exclusions such as \`-g '!node_modules'\` and inspect only relevant paths.
- Do not use \`find\` without either \`-maxdepth\` or an explicit pruning rule.
- Copy paths exactly from tool output. After a tool error, inspect the error and
  change approach instead of retrying variants of the same call.
- Keep the task bounded. Make the smallest relevant change, run its focused
  test, and report completion.`;

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
	let toolCalls = 0;

	pi.on("agent_start", () => {
		consecutiveToolErrors = 0;
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

	pi.on("tool_call", (event, ctx) => {
		if (consecutiveToolErrors >= MAX_CONSECUTIVE_TOOL_ERRORS) {
			return {
				block: true,
				reason: "Stopped after 3 consecutive tool errors; review the errors before continuing.",
				terminate: true,
			};
		}

		if (ctx.model?.id === "gemma4" && toolCalls >= MAX_GEMMA_TOOL_CALLS) {
			return {
				block: true,
				reason: "Stopped after Gemma reached its 24-call task limit.",
				terminate: true,
			};
		}

		toolCalls += 1;

		if (event.toolName !== "bash") return;
		const command = event.input.command;
		if (typeof command !== "string" || !isRecursiveListing(command)) return;

		return {
			block: true,
			reason: "Recursive listing blocked; use rg --files with explicit exclusions.",
		};
	});

	pi.on("tool_result", (event) => {
		consecutiveToolErrors = event.isError ? consecutiveToolErrors + 1 : 0;
	});
}
