import { createHash, randomBytes } from "node:crypto";
import { realpath } from "node:fs/promises";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

import { ReviewBridge } from "./bridge";

const STATUS_KEY = "nvim-review";

function shortSessionId(sessionId: string): string {
  return createHash("sha256").update(sessionId).digest("hex").slice(0, 5);
}

export default function nvimReviewExtension(pi: ExtensionAPI) {
  let bridge: ReviewBridge | undefined;

  pi.registerCommand("nvim", {
    description: "Start a Neovim review bridge for this Pi session",
    handler: async (_args, ctx) => {
      const runningManifest = bridge?.getManifest();
      if (bridge?.isActive() && runningManifest) {
        ctx.ui.notify(`Neovim session already running (${runningManifest.shortId})`, "info");
        return;
      }

      let projectRoot: string;
      try {
        projectRoot = await realpath(ctx.cwd);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        ctx.ui.notify(`Could not resolve Pi project root: ${message}`, "error");
        return;
      }

      const sessionId = ctx.sessionManager.getSessionId();
      const shortId = shortSessionId(sessionId);
      const token = randomBytes(32).toString("hex");

      // TODO: Move bridge ownership to a detached Pi RPC helper if the bridge
      // must survive the Pi process that started it.
      const candidate = new ReviewBridge({
        sessionId,
        shortId,
        projectRoot,
        sessionName: pi.getSessionName(),
        token,
        onSubmit: (prompt, count) => {
          const queued = !ctx.isIdle();
          if (queued) {
            pi.sendUserMessage(prompt, { deliverAs: "followUp" });
          } else {
            pi.sendUserMessage(prompt);
          }
          ctx.ui.notify(
            `${count} Neovim review comment${count === 1 ? "" : "s"} ${queued ? "queued" : "submitted"}`,
            "info",
          );
          return queued ? "queued" : "accepted";
        },
        onError: (error) => {
          ctx.ui.notify(`Neovim bridge error: ${error.message}`, "error");
        },
      });

      try {
        await candidate.start();
        bridge = candidate;
        ctx.ui.setStatus(STATUS_KEY, `nvim ${shortId}`);
        ctx.ui.notify(`Neovim session started (${shortId})`, "info");
      } catch (error) {
        await candidate.stop().catch(() => undefined);
        const message = error instanceof Error ? error.message : String(error);
        ctx.ui.notify(`Could not start Neovim session: ${message}`, "error");
      }
    },
  });

  pi.on("session_info_changed", async (event, ctx) => {
    try {
      await bridge?.updateSessionName(event.name);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      ctx.ui.notify(`Could not update Neovim session metadata: ${message}`, "warning");
    }
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    const current = bridge;
    bridge = undefined;
    try {
      await current?.stop();
    } finally {
      ctx.ui.setStatus(STATUS_KEY, undefined);
    }
  });
}
