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
		input: { path: "README.md" },
	});
	assert.deepEqual(result, {
		block: true,
		reason: "Stopped after 3 consecutive tool errors; review the errors before continuing.",
		terminate: true,
	});
}

{
	const test = harness();
	for (let index = 0; index < 3; index += 1) {
		await test.emit("tool_result", { isError: true });
	}
	await test.emit("tool_result", { isError: false });
	const result = await test.emit("tool_call", {
		toolName: "read",
		input: { path: "README.md" },
	});
	assert.equal(result, undefined);
}

{
	const test = harness();
	for (let index = 0; index < 24; index += 1) {
		const result = await test.emit("tool_call", {
			toolName: "read",
			input: { path: "README.md" },
		});
		assert.equal(result, undefined);
	}
	const result = await test.emit("tool_call", {
		toolName: "read",
		input: { path: "README.md" },
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
