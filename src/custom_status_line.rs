//! External, multiline status-line command integration.

use super::*;
use codex_ansi_escape::ansi_escape;
use codex_protocol::config_types::ServiceTier;
use serde::Serialize;
use std::ffi::OsString;
use std::process::Stdio;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use uuid::Uuid;

const COMMAND_ENV: &str = "CODEX_CUSTOM_STATUSLINE_COMMAND";
const INTERVAL_ENV: &str = "CODEX_CUSTOM_STATUSLINE_INTERVAL_MS";
const TIMEOUT_ENV: &str = "CODEX_CUSTOM_STATUSLINE_TIMEOUT_MS";
const MAX_LINES_ENV: &str = "CODEX_CUSTOM_STATUSLINE_MAX_LINES";
const DEFAULT_INTERVAL_MS: u64 = 1_000;
const DEFAULT_TIMEOUT_MS: u64 = 350;
const DEFAULT_MAX_LINES: usize = 6;
const MAX_OUTPUT_BYTES: usize = 64 * 1024;

#[derive(Debug)]
pub(super) struct CustomStatusLineRuntime {
    instance_id: Uuid,
    command: OsString,
    interval: Duration,
    timeout: Duration,
    max_lines: usize,
    next_request_id: u64,
    pending_request_id: Option<u64>,
    last_error: Option<String>,
}

impl CustomStatusLineRuntime {
    pub(super) fn from_env() -> Option<Self> {
        let command = std::env::var_os(COMMAND_ENV)?;
        if command.is_empty() {
            return None;
        }

        Some(Self {
            instance_id: Uuid::new_v4(),
            command,
            interval: Duration::from_millis(env_number(
                INTERVAL_ENV,
                DEFAULT_INTERVAL_MS,
                250,
                60_000,
            )),
            timeout: Duration::from_millis(env_number(TIMEOUT_ENV, DEFAULT_TIMEOUT_MS, 50, 5_000)),
            max_lines: env_number(MAX_LINES_ENV, DEFAULT_MAX_LINES as u64, 1, 8) as usize,
            next_request_id: 0,
            pending_request_id: None,
            last_error: None,
        })
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusSnapshot {
    version: u8,
    codex_version: &'static str,
    cwd: String,
    terminal_width: Option<usize>,
    model: ModelSnapshot,
    session: SessionSnapshot,
    context: ContextSnapshot,
    git: GitSnapshot,
    limits: LimitsSnapshot,
    tools: ToolsSnapshot,
    permissions: PermissionsSnapshot,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ModelSnapshot {
    name: String,
    reasoning_effort: String,
    service_tier: Option<String>,
    fast_mode: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionSnapshot {
    id: Option<String>,
    title: Option<String>,
    status: String,
    task_progress: Option<String>,
    current_task: Option<String>,
    token_usage_pending: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ToolsSnapshot {
    active: Vec<String>,
    last_edit: Option<String>,
    edits: usize,
    reads: usize,
    searches: usize,
    lists: usize,
    commands: usize,
    mcp_calls: usize,
    web_searches: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ContextSnapshot {
    window_tokens: Option<i64>,
    current_tokens: Option<i64>,
    used_percent: Option<i64>,
    remaining_percent: Option<i64>,
    total_tokens: i64,
    input_tokens: i64,
    cached_input_tokens: i64,
    output_tokens: i64,
    reasoning_output_tokens: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GitSnapshot {
    branch: Option<String>,
    project_root: Option<String>,
    pull_request: Option<PullRequestSnapshot>,
    additions: Option<u64>,
    deletions: Option<u64>,
}

#[derive(Serialize)]
struct PullRequestSnapshot {
    number: u64,
    url: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LimitsSnapshot {
    five_hour: Option<LimitSnapshot>,
    weekly: Option<LimitSnapshot>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LimitSnapshot {
    label: String,
    used_percent: f64,
    remaining_percent: f64,
    resets_at: Option<String>,
    window_minutes: Option<i64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PermissionsSnapshot {
    profile: String,
    approval_mode: String,
    collaboration_mode: Option<String>,
    can_cycle_collaboration_mode: bool,
}

impl ChatWidget {
    pub(super) fn custom_status_line_enabled(&self) -> bool {
        self.custom_status_line.is_some()
    }

    pub(crate) fn refresh_custom_status_line(&mut self) {
        if self
            .custom_status_line
            .as_ref()
            .is_none_or(|runtime| runtime.pending_request_id.is_some())
        {
            return;
        }

        let cwd = self.status_line_cwd().to_path_buf();
        let payload = match serde_json::to_vec(&self.custom_status_line_snapshot()) {
            Ok(payload) => payload,
            Err(err) => {
                tracing::warn!(error = %err, "failed to serialize custom status-line snapshot");
                return;
            }
        };

        let Some(runtime) = self.custom_status_line.as_mut() else {
            return;
        };
        runtime.next_request_id = runtime.next_request_id.wrapping_add(1);
        let request_id = runtime.next_request_id;
        runtime.pending_request_id = Some(request_id);
        let instance_id = runtime.instance_id;
        let command = runtime.command.clone();
        let timeout = runtime.timeout;
        let tx = self.app_event_tx.clone();

        tokio::spawn(async move {
            let result = run_status_line_command(command, cwd, payload, timeout).await;
            tx.send(AppEvent::CustomStatusLineRendered {
                instance_id,
                request_id,
                result,
            });
        });
    }

    pub(crate) fn finish_custom_status_line(
        &mut self,
        instance_id: Uuid,
        request_id: u64,
        result: Result<String, String>,
    ) {
        let Some(runtime) = self.custom_status_line.as_mut() else {
            return;
        };
        if runtime.instance_id != instance_id || runtime.pending_request_id != Some(request_id) {
            return;
        }
        runtime.pending_request_id = None;

        match result {
            Ok(output) => {
                runtime.last_error = None;
                self.bottom_pane
                    .set_custom_status_line(parse_status_line_output(&output, runtime.max_lines));
            }
            Err(error) => {
                if runtime.last_error.as_deref() != Some(error.as_str()) {
                    tracing::warn!(error = %error, "custom status-line command failed");
                    runtime.last_error = Some(error);
                }
            }
        }

        let tx = self.app_event_tx.clone();
        let interval = runtime.interval;
        tokio::spawn(async move {
            tokio::time::sleep(interval).await;
            tx.send(AppEvent::CustomStatusLineTick {
                instance_id,
                after_request_id: request_id,
            });
        });
    }

    pub(crate) fn handle_custom_status_line_tick(
        &mut self,
        instance_id: Uuid,
        after_request_id: u64,
    ) {
        let should_refresh = self.custom_status_line.as_ref().is_some_and(|runtime| {
            runtime.instance_id == instance_id
                && runtime.pending_request_id.is_none()
                && runtime.next_request_id == after_request_id
        });
        if should_refresh {
            self.refresh_custom_status_line();
        }
    }

    fn custom_status_line_snapshot(&mut self) -> StatusSnapshot {
        let usage = self.status_line_total_usage();
        let current_tokens = self
            .token_info
            .as_ref()
            .map(|info| info.last_token_usage.tokens_in_context_window());
        let project_root = self.status_line_value_for_item(StatusLineItem::ProjectRoot);
        let git_summary = self.status_line_git_summary.as_ref();
        let pull_request = git_summary
            .and_then(|summary| summary.pull_request.as_ref())
            .map(|pull_request| PullRequestSnapshot {
                number: pull_request.number,
                url: pull_request.url.clone(),
            });
        let additions = git_summary
            .and_then(|summary| summary.branch_change_stats.as_ref())
            .map(|stats| stats.additions);
        let deletions = git_summary
            .and_then(|summary| summary.branch_change_stats.as_ref())
            .map(|stats| stats.deletions);
        let codex_limits = self.rate_limit_snapshots_by_limit_id.get("codex");
        let five_hour = codex_limits
            .and_then(super::status_surfaces::five_hour_status_window)
            .map(|(window, is_secondary)| limit_snapshot(window, is_secondary));
        let weekly = codex_limits
            .and_then(super::status_surfaces::weekly_status_window)
            .map(|(window, is_secondary)| limit_snapshot(window, is_secondary));

        StatusSnapshot {
            version: 2,
            codex_version: CODEX_CLI_VERSION,
            cwd: self.status_line_cwd().to_string_lossy().into_owned(),
            terminal_width: self.last_rendered_width.get(),
            model: ModelSnapshot {
                name: self.model_display_name().to_string(),
                reasoning_effort: self
                    .status_line_value_for_item(StatusLineItem::Reasoning)
                    .unwrap_or_else(|| "default".to_string()),
                service_tier: self.current_service_tier().map(ToString::to_string),
                fast_mode: self.current_service_tier() == Some(ServiceTier::Fast.request_value()),
            },
            session: SessionSnapshot {
                id: self.thread_id.map(|id| id.to_string()),
                title: self.thread_name.clone(),
                status: self.run_state_status_text(),
                task_progress: self.terminal_title_task_progress(),
                current_task: self.transcript.last_plan_step.clone(),
                token_usage_pending: self.token_usage_pending,
            },
            context: ContextSnapshot {
                window_tokens: self.status_line_context_window_size(),
                current_tokens,
                used_percent: self.status_line_context_used_percent(),
                remaining_percent: self.status_line_context_remaining_percent(),
                total_tokens: usage.total_tokens,
                input_tokens: usage.input_tokens,
                cached_input_tokens: usage.cached_input_tokens,
                output_tokens: usage.output_tokens,
                reasoning_output_tokens: usage.reasoning_output_tokens,
            },
            git: GitSnapshot {
                branch: self.status_line_branch.clone(),
                project_root,
                pull_request,
                additions,
                deletions,
            },
            limits: LimitsSnapshot { five_hour, weekly },
            tools: ToolsSnapshot {
                active: self.active_tool_labels(),
                last_edit: self.transcript.tool_activity.last_edit.clone(),
                edits: self.transcript.tool_activity.edits,
                reads: self.transcript.tool_activity.reads,
                searches: self.transcript.tool_activity.searches,
                lists: self.transcript.tool_activity.lists,
                commands: self.transcript.tool_activity.commands,
                mcp_calls: self.transcript.tool_activity.mcp_calls,
                web_searches: self.transcript.tool_activity.web_searches,
            },
            permissions: PermissionsSnapshot {
                profile: self
                    .status_line_value_for_item(StatusLineItem::Permissions)
                    .unwrap_or_default(),
                approval_mode: self
                    .status_line_value_for_item(StatusLineItem::ApprovalMode)
                    .unwrap_or_default(),
                collaboration_mode: self.collaboration_mode_label().map(ToString::to_string),
                can_cycle_collaboration_mode: self.collaboration_modes_enabled()
                    && !self.bottom_pane.is_task_running(),
            },
        }
    }

    fn active_tool_labels(&self) -> Vec<String> {
        let mut active = Vec::new();
        if let Some(path) = self.transcript.tool_activity.active_edit.as_ref() {
            active.push(format!("Edit: {path}"));
        }

        let mut running_ids = self.running_commands.keys().collect::<Vec<_>>();
        running_ids.sort();
        for id in running_ids {
            let Some(command) = self.running_commands.get(id) else {
                continue;
            };
            if matches!(
                command.source,
                ExecCommandSource::UserShell | ExecCommandSource::UnifiedExecInteraction
            ) {
                continue;
            }
            if command.parsed_cmd.is_empty() {
                active.push("Command".to_string());
                continue;
            }
            for parsed in &command.parsed_cmd {
                let label = match parsed {
                    codex_protocol::parse_command::ParsedCommand::Read { name, .. } => {
                        format!("Read: {name}")
                    }
                    codex_protocol::parse_command::ParsedCommand::ListFiles { path, .. } => path
                        .as_ref()
                        .map_or_else(|| "List".to_string(), |path| format!("List: {path}")),
                    codex_protocol::parse_command::ParsedCommand::Search { query, .. } => query
                        .as_ref()
                        .map_or_else(|| "Grep".to_string(), |query| format!("Grep: {query}")),
                    codex_protocol::parse_command::ParsedCommand::Unknown { .. } => {
                        "Command".to_string()
                    }
                };
                active.push(label);
            }
        }
        active
    }
}

fn env_number(name: &str, default: u64, min: u64, max: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
        .clamp(min, max)
}

fn limit_snapshot(window: &RateLimitWindowDisplay, is_secondary: bool) -> LimitSnapshot {
    LimitSnapshot {
        label: limit_label_for_window(window.window_minutes, is_secondary),
        used_percent: window.used_percent,
        remaining_percent: (100.0 - window.used_percent).clamp(0.0, 100.0),
        resets_at: window.resets_at.clone(),
        window_minutes: window.window_minutes,
    }
}

async fn run_status_line_command(
    command: OsString,
    cwd: PathBuf,
    payload: Vec<u8>,
    timeout: Duration,
) -> Result<String, String> {
    let run = async move {
        let mut child = Command::new(&command)
            .current_dir(cwd)
            .env("CODEX_CUSTOM_STATUSLINE_VERSION", "2")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|err| format!("could not start {:?}: {err}", command))?;

        let Some(mut stdin) = child.stdin.take() else {
            return Err("custom status-line stdin was unavailable".to_string());
        };
        stdin
            .write_all(&payload)
            .await
            .map_err(|err| format!("could not write status snapshot: {err}"))?;
        drop(stdin);

        let output = child
            .wait_with_output()
            .await
            .map_err(|err| format!("could not wait for custom status-line command: {err}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let detail = stderr.trim().chars().take(512).collect::<String>();
            return Err(if detail.is_empty() {
                format!("command exited with {}", output.status)
            } else {
                format!("command exited with {}: {detail}", output.status)
            });
        }
        if output.stdout.len() > MAX_OUTPUT_BYTES {
            return Err(format!(
                "command output exceeded the {MAX_OUTPUT_BYTES}-byte limit"
            ));
        }
        String::from_utf8(output.stdout)
            .map_err(|err| format!("command output was not valid UTF-8: {err}"))
    };

    tokio::time::timeout(timeout, run)
        .await
        .map_err(|_| format!("command timed out after {} ms", timeout.as_millis()))?
}

fn parse_status_line_output(output: &str, max_lines: usize) -> Option<Vec<Line<'static>>> {
    let normalized = output.replace("\r\n", "\n").replace('\r', "\n");
    let output = normalized.trim_matches('\n');
    if output.is_empty() {
        return None;
    }

    let mut lines = ansi_escape(output).lines;
    lines.truncate(max_lines);
    (!lines.is_empty()).then_some(lines)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::style::Color;

    #[test]
    fn parses_multiline_ansi_and_enforces_line_limit() {
        let lines = parse_status_line_output("\x1b[31mred\x1b[0m\r\nsecond\nthird", 2)
            .expect("expected rendered lines");

        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].spans[0].content, "red");
        assert_eq!(lines[0].spans[0].style.fg, Some(Color::Red));
        assert_eq!(lines[1].spans[0].content, "second");
    }

    #[test]
    fn empty_output_clears_custom_status_line() {
        assert!(parse_status_line_output("\r\n", 3).is_none());
    }
}
