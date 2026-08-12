import assert from "node:assert/strict";
import test from "node:test";

import { render } from "./statusline.mjs";

const snapshot = {
  version: 2,
  terminalWidth: 120,
  cwd: "/work/codex-hud",
  model: { name: "gpt-5.6-sol", reasoningEffort: "max", fastMode: false },
  session: { status: "Working", taskProgress: "Tasks 2/5", currentTask: "Fix authentication bug" },
  context: {
    usedPercent: 45,
    currentTokens: 62000,
    windowTokens: 128000,
    inputTokens: 50000,
    outputTokens: 12000,
    cachedInputTokens: 18000,
  },
  git: { projectRoot: "codex-hud", branch: "main", additions: 12, deletions: 3 },
  tools: { active: [], lastEdit: "src/auth.ts", edits: 1, reads: 3, searches: 2, lists: 0, commands: 0, mcpCalls: 0, webSearches: 0 },
  limits: {
    fiveHour: { label: "5h", usedPercent: 12, remainingPercent: 88, resetsAt: "4:30 PM" },
    weekly: { label: "weekly", usedPercent: 28, remainingPercent: 72, resetsAt: "Friday" },
  },
  permissions: {
    profile: "Workspace",
    approvalMode: "Ask for approval",
    collaborationMode: "Default",
    canCycleCollaborationMode: true,
  },
};

test("renders native HUD data in Claude-HUD-style lines", () => {
  process.env.NO_COLOR = "1";
  try {
    const lines = render(snapshot, {}).split("\n");
    assert.equal(lines.length, 6);
    assert.match(lines[0], /^\[GPT 5\.6 Sol\]/);
    assert.doesNotMatch(lines[0], /^Codex/);
    assert.match(lines[1], /^Context \u2588{5}\u2591{5} 45%/u);
    assert.equal(lines[2], "✓ Edit: auth.ts | ✓ Read ×3 | ✓ Grep ×2");
    assert.equal(lines[3], "▸ Fix authentication bug (2/5)");
    assert.match(lines[4], /88% left/);
    assert.equal(lines[5], "⏵⏵ default mode on (shift+tab to cycle) | Workspace / Ask for approval");
  } finally {
    delete process.env.NO_COLOR;
  }
});

test("omits unavailable optional activity and honors line order", () => {
  process.env.NO_COLOR = "1";
  try {
    const output = render(
      {
        ...snapshot,
        terminalWidth: 70,
        session: { status: "Ready" },
        tools: {},
        limits: {},
        permissions: { collaborationMode: "Plan", canCycleCollaborationMode: true },
      },
      { lineOrder: ["tools", "todo", "context", "mode"] },
    );
    const lines = output.split("\n");
    assert.equal(lines.length, 2);
    assert.ok(lines[0].startsWith("Context"));
    assert.equal(lines[1], "⏸ plan mode on");
    assert.doesNotMatch(output, /\x1b\[/);
  } finally {
    delete process.env.NO_COLOR;
  }
});

test("can show reasoning inside the model badge", () => {
  process.env.NO_COLOR = "1";
  try {
    const output = render(snapshot, { lineOrder: ["header"], show: { reasoning: true } });
    assert.match(output, /^\[GPT 5\.6 Sol max\]/);
  } finally {
    delete process.env.NO_COLOR;
  }
});

test("shows structured in-flight tool activity", () => {
  process.env.NO_COLOR = "1";
  try {
    const output = render(
      { ...snapshot, tools: { active: ["Edit: auth.ts"], reads: 3, searches: 2 } },
      { lineOrder: ["tools"] },
    );
    assert.equal(output, "◐ Edit: auth.ts | ✓ Read ×3 | ✓ Grep ×2");
  } finally {
    delete process.env.NO_COLOR;
  }
});
