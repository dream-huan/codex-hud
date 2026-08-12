#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const RESET = "\x1b[0m";
const DEFAULT_CONFIG = {
  lineOrder: ["header", "context", "tools", "todo", "limits", "mode"],
  barWidth: 10,
  separator: " | ",
  show: {
    status: true,
    project: true,
    branch: true,
    reasoning: false,
    tools: true,
    todo: true,
    limits: true,
    mode: true,
    tokenBreakdown: false,
    resetTimes: true,
  },
  colors: {
    label: "brightBlack",
    model: "brightCyan",
    project: "brightBlue",
    branch: "brightMagenta",
    good: "brightGreen",
    warning: "brightYellow",
    danger: "brightRed",
    value: "white",
    muted: "brightBlack",
  },
};

const ANSI_COLORS = {
  black: 30,
  red: 31,
  green: 32,
  yellow: 33,
  blue: 34,
  magenta: 35,
  cyan: 36,
  white: 37,
  brightBlack: 90,
  brightRed: 91,
  brightGreen: 92,
  brightYellow: 93,
  brightBlue: 94,
  brightMagenta: 95,
  brightCyan: 96,
  brightWhite: 97,
};

function mergeConfig(base, override) {
  return {
    ...base,
    ...override,
    show: { ...base.show, ...(override.show ?? {}) },
    colors: { ...base.colors, ...(override.colors ?? {}) },
  };
}

function loadConfig(configPath = process.env.CODEX_HUD_CONFIG) {
  const candidate = configPath || path.join(os.homedir(), ".config", "codex-hud", "config.json");
  if (!fs.existsSync(candidate)) return DEFAULT_CONFIG;
  return mergeConfig(DEFAULT_CONFIG, JSON.parse(fs.readFileSync(candidate, "utf8")));
}

function paint(text, colorName, config, bold = false) {
  if (!text) return "";
  if (process.env.NO_COLOR !== undefined) return text;
  const code = ANSI_COLORS[config.colors[colorName]];
  if (!code) return text;
  return `\x1b[${bold ? "1;" : ""}${code}m${text}${RESET}`;
}

function compactNumber(value) {
  if (!Number.isFinite(value)) return "?";
  const absolute = Math.abs(value);
  if (absolute >= 1_000_000) return `${(value / 1_000_000).toFixed(1).replace(/\.0$/, "")}m`;
  if (absolute >= 1_000) return `${(value / 1_000).toFixed(1).replace(/\.0$/, "")}k`;
  return String(Math.round(value));
}

function basename(value) {
  if (!value) return "";
  const normalized = value.replace(/[\\/]+$/, "");
  return normalized.split(/[\\/]/).pop() || value;
}

function formatModelName(value) {
  return String(value || "loading")
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((part) => {
      const lower = part.toLowerCase();
      if (lower === "gpt") return "GPT";
      if (/^\d+(?:\.\d+)*$/.test(part)) return part;
      return `${part.charAt(0).toUpperCase()}${part.slice(1).toLowerCase()}`;
    })
    .join(" ");
}

function progressBar(percent, width) {
  const value = Math.max(0, Math.min(100, Number(percent) || 0));
  const cells = Math.max(4, Math.min(30, Number(width) || 10));
  const filled = Math.round((value / 100) * cells);
  return `${"█".repeat(filled)}${"░".repeat(cells - filled)}`;
}

function usageColor(usedPercent) {
  if (usedPercent >= 90) return "danger";
  if (usedPercent >= 70) return "warning";
  return "good";
}

function statusColor(status) {
  return status === "Ready" ? "good" : status === "Waiting" ? "warning" : "model";
}

function join(parts, config) {
  return parts.filter(Boolean).join(paint(config.separator, "muted", config));
}

function headerLine(snapshot, config, narrow) {
  const model = snapshot.model ?? {};
  const git = snapshot.git ?? {};
  const session = snapshot.session ?? {};
  const modelParts = [formatModelName(model.name)];
  if (config.show.reasoning && model.reasoningEffort) modelParts.push(model.reasoningEffort);
  if (model.fastMode) modelParts.push("Fast");
  const project = git.projectRoot || basename(snapshot.cwd);
  const parts = [paint(`[${modelParts.join(" ")}]`, "model", config, true)];
  if (config.show.project && project) parts.push(paint(project, "project", config));
  if (config.show.branch && git.branch) {
    parts.push(`${paint("git:", "label", config)}${paint(git.branch, "branch", config)}`);
  }
  if (!narrow && git.pullRequest?.number) parts.push(paint(`PR #${git.pullRequest.number}`, "branch", config));
  if (!narrow && Number.isFinite(git.additions) && Number.isFinite(git.deletions)) {
    parts.push(`${paint(`+${git.additions}`, "good", config)} ${paint(`-${git.deletions}`, "danger", config)}`);
  }
  if (config.show.status && session.status) parts.push(paint(session.status, statusColor(session.status), config, true));
  return join(parts, config);
}

function contextLine(snapshot, config, narrow) {
  const context = snapshot.context ?? {};
  const used = Math.round(Number.isFinite(context.usedPercent) ? context.usedPercent : 0);
  const barWidth = narrow ? Math.min(config.barWidth, 10) : config.barWidth;
  const summary = `${paint("Context", "label", config, true)} ${paint(progressBar(used, barWidth), usageColor(used), config)} ${paint(`${used}%`, usageColor(used), config, true)}`;
  const parts = [summary];
  if (Number.isFinite(context.currentTokens) && Number.isFinite(context.windowTokens)) {
    parts.push(paint(`${compactNumber(context.currentTokens)}/${compactNumber(context.windowTokens)}`, "value", config));
  }
  if (!narrow && config.show.tokenBreakdown) {
    const tokenParts = [];
    if (Number.isFinite(context.inputTokens)) tokenParts.push(`in ${compactNumber(context.inputTokens)}`);
    if (Number.isFinite(context.outputTokens)) tokenParts.push(`out ${compactNumber(context.outputTokens)}`);
    if (Number.isFinite(context.cachedInputTokens) && context.cachedInputTokens > 0) {
      tokenParts.push(`cached ${compactNumber(context.cachedInputTokens)}`);
    }
    if (tokenParts.length) parts.push(paint(tokenParts.join(" "), "muted", config));
  }
  return join(parts, config);
}

function toolPart(label, count, config, detail = "") {
  if (!Number.isFinite(count) || count <= 0) return "";
  const suffix = count > 1 ? ` ×${count}` : "";
  return `${paint("✓", "good", config, true)} ${paint(`${label}${detail ? `: ${detail}` : ""}${suffix}`, "value", config)}`;
}

function toolsLine(snapshot, config, narrow) {
  if (!config.show.tools) return "";
  const tools = snapshot.tools ?? {};
  const active = Array.isArray(tools.active) ? tools.active.filter(Boolean) : [];
  const parts = [
    ...active.slice(0, narrow ? 1 : 2).map((label) => `${paint("◐", "warning", config, true)} ${paint(label, "value", config)}`),
    toolPart("Edit", tools.edits, config, tools.lastEdit ? basename(tools.lastEdit) : ""),
    toolPart("Read", tools.reads, config),
    toolPart("Grep", tools.searches, config),
    toolPart("List", tools.lists, config),
  ];
  if (!narrow) {
    parts.push(toolPart("Command", tools.commands, config));
    parts.push(toolPart("MCP", tools.mcpCalls, config));
    parts.push(toolPart("Web", tools.webSearches, config));
  }
  return join(parts, config);
}

function todoLine(snapshot, config) {
  if (!config.show.todo) return "";
  const session = snapshot.session ?? {};
  if (!session.taskProgress) return "";
  const progress = String(session.taskProgress).replace(/^Tasks\s+/i, "");
  const task = session.currentTask || "Tasks";
  return `${paint("▸", "model", config, true)} ${paint(`${task} (${progress})`, "value", config)}`;
}

function limitPart(limit, config, narrow) {
  if (!limit) return "";
  const used = Number.isFinite(limit.usedPercent) ? limit.usedPercent : 0;
  const remaining = Number.isFinite(limit.remainingPercent) ? Math.round(limit.remainingPercent) : Math.round(100 - used);
  const reset = !narrow && config.show.resetTimes && limit.resetsAt ? ` reset ${limit.resetsAt}` : "";
  return `${paint(limit.label, "label", config, true)} ${paint(progressBar(used, narrow ? 6 : 8), usageColor(used), config)} ${paint(`${remaining}% left`, usageColor(used), config, true)}${paint(reset, "muted", config)}`;
}

function limitsLine(snapshot, config, narrow) {
  if (!config.show.limits) return "";
  const limits = snapshot.limits ?? {};
  const visible = [limitPart(limits.fiveHour, config, narrow), limitPart(limits.weekly, config, narrow)].filter(Boolean);
  return visible.join(paint(config.separator, "muted", config));
}

function modeLine(snapshot, config, narrow) {
  if (!config.show.mode) return "";
  const permissions = snapshot.permissions ?? {};
  const mode = permissions.collaborationMode;
  const modeIcon = String(mode).toLowerCase() === "plan" ? "⏸" : "⏵⏵";
  const modeText = mode ? `${String(mode).toLowerCase()} mode on` : "";
  const cycleHint = mode && permissions.canCycleCollaborationMode && !narrow ? " (shift+tab to cycle)" : "";
  const access = [permissions.profile, permissions.approvalMode].filter(Boolean).join(" / ");
  return join([
    modeText ? paint(`${modeIcon} ${modeText}${cycleHint}`, "warning", config) : "",
    access ? paint(access, "muted", config) : "",
  ], config);
}

export function render(snapshot, configOverride = {}) {
  const config = mergeConfig(DEFAULT_CONFIG, configOverride);
  const width = Number(snapshot.terminalWidth) || Number(process.env.COLUMNS) || 100;
  const narrow = width < 78;
  const renderers = {
    header: () => headerLine(snapshot, config, narrow),
    context: () => contextLine(snapshot, config, narrow),
    tools: () => toolsLine(snapshot, config, narrow),
    todo: () => todoLine(snapshot, config),
    limits: () => limitsLine(snapshot, config, narrow),
    mode: () => modeLine(snapshot, config, narrow),
  };
  return config.lineOrder
    .map((name) => renderers[name]?.())
    .filter(Boolean)
    .join("\n");
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

async function main() {
  const input = await readStdin();
  const snapshot = JSON.parse(input);
  process.stdout.write(render(snapshot, loadConfig()));
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (import.meta.url === invokedPath) {
  main().catch((error) => {
    process.stderr.write(`codex-hud renderer: ${error.message}\n`);
    process.exitCode = 1;
  });
}
