#!/usr/bin/env node

import assert from "node:assert/strict";
import guardExtension from "./pi-local-guard.ts";

function harness(modelId = "gemma4") {
	const handlers = new Map();
	const pi = {
		on(event, handler) {
			const eventHandlers = handlers.get(event) ?? [];
			eventHandlers.push(handler);
			handlers.set(event, eventHandlers);
		},
	};
	const ctx = {
		model: { id: modelId },
	};

	guardExtension(pi);

	return {
		async emit(event, payload = {}) {
			let result;
			for (const handler of handlers.get(event) ?? []) {
				result = (await handler(payload, ctx)) ?? result;
			}
			return result;
		},
	};
}

{
	const test = harness();
	const result = await test.emit("before_agent_start", { systemPrompt: "base" });
	assert.match(result.systemPrompt, /Never run recursive directory listings/);
	assert.match(result.systemPrompt, /six inspection calls/);
}

for (const input of [
	{ path: "README.md" },
	{ path: "README.md", limit: 201 },
]) {
	const test = harness("qwen38");
	const result = await test.emit("tool_call", { toolName: "read", input });
	assert.equal(result.block, true);
	assert.match(result.reason, /at most 200 lines/);
}

{
	const test = harness("qwen38");
	const result = await test.emit("tool_call", {
		toolName: "read",
		input: { path: "README.md", limit: 200 },
	});
	assert.equal(result, undefined);
}

for (const command of ["ls -R", "ls -laR browser-extensions", "find . -name '*.js'"]) {
	const test = harness();
	const result = await test.emit("tool_call", {
		toolName: "bash",
		input: { command },
	});
	assert.equal(result.block, true, command);
	assert.equal(result.terminate, undefined, command);
}

{
	const test = harness();
	for (let index = 0; index < 3; index += 1) {
		await test.emit("tool_result", { isError: true });
	}
	const result = await test.emit("tool_call", {
		toolName: "read",
		input: { path: "README.md", limit: 20 },
	});
	assert.deepEqual(result, {
		block: true,
		reason: "Stopped after 3 consecutive tool errors; review the errors before continuing.",
		terminate: true,
	});
}

{
	const test = harness("qwen38");
	for (let index = 0; index < 6; index += 1) {
		const result = await test.emit("tool_call", {
			toolName: "read",
			input: { path: "README.md", limit: 20 },
		});
		assert.equal(result, undefined);
	}
	const result = await test.emit("tool_call", {
		toolName: "read",
		input: { path: "README.md", limit: 20 },
	});
	assert.equal(result.block, true);
	assert.match(result.reason, /inspection budget/);
	assert.equal(result.terminate, undefined);

	await test.emit("tool_call", {
		toolName: "edit",
		input: { path: "README.md", oldText: "old", newText: "new" },
	});
	await test.emit("tool_result", { toolName: "edit", isError: true });
	assert.equal((await test.emit("tool_call", {
		toolName: "read",
		input: { path: "README.md", limit: 20 },
	})).block, true);

	await test.emit("tool_call", {
		toolName: "edit",
		input: { path: "README.md", oldText: "old", newText: "new" },
	});
	await test.emit("tool_result", { toolName: "edit", isError: false });
	assert.equal(await test.emit("tool_call", {
		toolName: "read",
		input: { path: "README.md", limit: 20 },
	}), undefined);
}

{
	const test = harness("qwen38");
	await test.emit("tool_call", {
		toolName: "edit",
		input: { path: "README.md", oldText: "old", newText: "new" },
	});
	await test.emit("tool_result", { toolName: "edit", isError: false });
	for (let index = 1; index < 16; index += 1) {
		assert.equal(await test.emit("tool_call", {
			toolName: "read",
			input: { path: "README.md", limit: 20 },
		}), undefined);
	}
	const result = await test.emit("tool_call", {
		toolName: "read",
		input: { path: "README.md", limit: 20 },
	});
	assert.equal(result.block, true);
	assert.equal(result.terminate, true);
}

{
	const test = harness("qwen38");
	const result = await test.emit("session_before_compact", {
		preparation: {
			firstKeptEntryId: "keep-this",
			tokensBefore: 12_000,
			previousSummary: undefined,
			messagesToSummarize: [{
				role: "assistant",
				content: [{ type: "thinking", thinking: "The route needs session authentication." }],
			}],
			turnPrefixMessages: [],
			fileOps: {
				read: new Set(["lib/app.rb"]),
				written: new Set(),
				edited: new Set(["test/app_test.rb"]),
			},
		},
		branchEntries: [{
			type: "message",
			message: { role: "user", content: "Add sign-in to the admin area." },
		}],
	});
	assert.equal(result.compaction.firstKeptEntryId, "keep-this");
	assert.equal(result.compaction.tokensBefore, 12_000);
	assert.match(result.compaction.summary, /Add sign-in to the admin area/);
	assert.match(result.compaction.summary, /route needs session authentication/);
	assert.deepEqual(result.compaction.details, {
		readFiles: ["lib/app.rb"],
		modifiedFiles: ["test/app_test.rb"],
	});
	assert.ok(result.compaction.summary.length < 5_000);
}

{
	const test = harness("gemma4");
	assert.equal(await test.emit("session_before_compact", {
		preparation: {},
		branchEntries: [],
	}), undefined);
}

{
	const test = harness();
	for (let index = 0; index < 3; index += 1) {
		await test.emit("tool_result", { isError: true });
	}
	await test.emit("tool_result", { isError: false });
	const result = await test.emit("tool_call", {
		toolName: "read",
		input: { path: "README.md", limit: 20 },
	});
	assert.equal(result, undefined);
}

{
	const test = harness();
	for (let index = 0; index < 24; index += 1) {
		const result = await test.emit("tool_call", {
			toolName: "read",
			input: { path: "README.md", limit: 20 },
		});
		assert.equal(result, undefined);
	}
	const result = await test.emit("tool_call", {
		toolName: "read",
		input: { path: "README.md", limit: 20 },
	});
	assert.equal(result.block, true);
	assert.equal(result.terminate, true);
}

{
	const test = harness();
	const payload = { messages: [] };
	const result = await test.emit("before_provider_request", { payload });
	assert.deepEqual(result, {
		messages: [],
		chat_template_kwargs: {
			enable_thinking: true,
			preserve_thinking: true,
		},
	});
}

{
	const test = harness("qwen38");
	const payload = { messages: [] };
	const result = await test.emit("before_provider_request", { payload });
	assert.equal(result, undefined);
}

console.log('at=info msg="Pi local guard tests passed"');
