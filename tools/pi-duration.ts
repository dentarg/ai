import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";

interface DurationEntry {
	text: string;
}

function formatDuration(milliseconds: number): string {
	const totalSeconds = Math.max(0, Math.round(milliseconds / 1000));
	const hours = Math.floor(totalSeconds / 3600);
	const minutes = Math.floor((totalSeconds % 3600) / 60);
	const seconds = totalSeconds % 60;

	if (hours > 0) return `${hours}h ${minutes}m ${seconds}s`;
	if (minutes > 0) return `${minutes}m ${seconds}s`;
	return `${seconds}s`;
}

export default function (pi: ExtensionAPI) {
	let startedAt: number | undefined;

	pi.registerEntryRenderer<DurationEntry>("cooked-duration", (entry, _options, theme) => {
		return new Text(theme.fg("dim", entry.data?.text ?? ""), 0, 0);
	});

	pi.on("agent_start", () => {
		startedAt ??= Date.now();
	});

	pi.on("agent_settled", (_event, ctx) => {
		if (startedAt === undefined) return;

		const now = new Date();
		const duration = formatDuration(now.getTime() - startedAt);
		const clock = now.toLocaleTimeString(undefined, {
			hour: "numeric",
			minute: "2-digit",
		});
		const text = `✻ Cooked for ${duration} · done ${clock}`;
		startedAt = undefined;

		if (process.env.LOCAL_CODE_PRINT_MODE === "1") {
			console.error(text);
		} else {
			pi.appendEntry<DurationEntry>("cooked-duration", { text });
			ctx.ui.setStatus("cooked-duration", ctx.ui.theme.fg("dim", text));
		}
	});
}
