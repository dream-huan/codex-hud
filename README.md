# codex-hud

为 Codex CLI 增加可编程、多行、彩色 HUD。默认显示模型、项目、Git 分支、上下文、工具活动、Todo、用量限制、协作模式和权限。

> [!IMPORTANT]
> Codex CLI 目前没有公开的“执行外部命令并渲染多行状态栏”配置。本项目是基于 OpenAI Codex `rust-v0.147.0` 的源码补丁，不是官方插件。它安装独立的 `codex-hud` 命令，不会覆盖系统中的官方 `codex`。

## 支持范围

- 提供免编译安装包并已验证：Linux x86_64（GNU/glibc）。
- Linux arm64 和 macOS x86_64/arm64 暂无预编译包，可以按“从源码构建”章节自行构建。
- Windows 请在 WSL2 中按 Linux 方式安装；暂不支持原生 Windows。
- 固定 Codex 版本：`0.147.0`（上游提交 `be6e8eac029b183056b7e4402879f15d2c85f61b`）。

普通安装直接下载 GitHub Release 中的预编译运行包，不需要 Rust、Python、C/C++ 工具链，也不会在用户机器上构建 Codex。

默认效果大致如下；没有真实数据的可选行会自动隐藏：

```text
[GPT 5.6 Sol] | codex-hud | git:main | Tasks 0/4 | Working
Context █████░░░░░ 45% | 75k/258.4k
✓ Edit: auth.ts | ✓ Read ×3 | ✓ Grep ×2
▸ Fix authentication bug (2/5)
5h █░░░░░░░ 88% left | weekly ██░░░░░░ 72% left
⏵⏵ default mode on (shift+tab to cycle) | Workspace / Ask for approval
```

Tools 统计来自 Codex 的结构化命令/文件变更事件：`◐` 表示正在执行，`✓` 只累计当前 turn 成功完成的活动。Todo 来自 `update_plan`。Shift+Tab 切换的是 Codex 原生 `Default`/`Plan` 协作模式；sandbox profile 和 approval mode 单独显示，不伪装成 Claude Code 的三档权限模式。当前版本没有输出子代理状态行，因为 HUD 所在的 `ChatWidget` 没有完整、持久的子代理状态快照。

## 快速安装

需要 Linux x86_64、`curl`、`tar`、`sha256sum` 和 Node.js 18+。运行：

```bash
curl -fsSL https://raw.githubusercontent.com/dream-huan/codex-hud/main/scripts/install.sh | sh
```

安装器会自动下载最新 Release，并在解压前校验 SHA-256。不会执行 Cargo，也不会拉取 Codex 源码。

如果更愿意先检查脚本，也可以 clone 后执行；行为相同，仍然下载预编译包：

```bash
git clone https://github.com/dream-huan/codex-hud.git
cd codex-hud
./scripts/install.sh
```

安装指定版本：

```bash
CODEX_HUD_VERSION=v0.1.1 ./scripts/install.sh
```

如果 `~/.local/bin` 不在 `PATH` 中，把下面一行加入 `~/.bashrc` 或 `~/.zshrc`：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

重新加载 shell 配置或打开新终端后运行：

```bash
codex-hud
```

它复用 Codex 的 `~/.codex` 配置和登录状态。尚未登录时可以执行：

```bash
codex-hud login
```

安装后的文件：

```text
~/.local/bin/codex-hud                 命令入口
~/.local/share/codex-hud/              完整运行包、渲染器和默认配置
~/.config/codex-hud/config.json        用户配置
```

官方 `codex` 命令和安装目录不会被修改。

## 从源码构建

这部分只面向修改 Rust 补丁或尚无预编译包的平台。需要 Git、Python 3.11+、C/C++ 构建工具、`pkg-config`、Rustup、Node.js 18+，并建议准备 30 GB 可用磁盘和至少 8 GB 内存。首次构建通常需要 20–60 分钟。

```bash
git clone https://github.com/dream-huan/codex-hud.git
cd codex-hud
CODEX_BUILD_JOBS=4 ./scripts/build.sh
CODEX_HUD_PACKAGE_SOURCE=dist/package ./scripts/install.sh
```

构建产物位于 `dist/package/`。脚本使用上游的标准 package builder，包中包含主程序、`codex-code-mode-host`、Linux sandbox、ripgrep 和 patched zsh 等运行时资源。

可用的构建变量：

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `CODEX_BUILD_JOBS` | Cargo 默认值 | 限制并行编译任务数 |
| `CODEX_HUD_PROFILE` | `release` | Cargo profile；本地快速试验可用 `dev-small` |
| `CODEX_HUD_TARGET` | 自动检测 | 指定上游 package builder 支持的 Rust target |
| `CODEX_HUD_SOURCE_DIR` | `.cache/codex` | 使用已有的、固定版本的 Codex 源码目录 |
| `CODEX_HUD_STRIP` | `1` | Linux 上是否 strip 主程序和 helper |

## 配置 HUD

编辑 `~/.config/codex-hud/config.json`。渲染器每秒重新读取配置，不需要重启 Codex。

```json
{
  "lineOrder": ["header", "context", "tools", "todo", "limits", "mode"],
  "barWidth": 10,
  "separator": " | ",
  "show": {
    "status": true,
    "project": true,
    "branch": true,
    "reasoning": false,
    "taskProgress": true,
    "tools": true,
    "todo": true,
    "limits": true,
    "mode": true,
    "tokenBreakdown": true,
    "resetTimes": true
  },
  "colors": {
    "label": "brightBlack",
    "model": "brightCyan",
    "project": "brightBlue",
    "branch": "brightMagenta",
    "good": "brightGreen",
    "warning": "brightYellow",
    "danger": "brightRed",
    "value": "white",
    "muted": "brightBlack"
  }
}
```

`lineOrder` 可以重新排序或隐藏 `header`、`context`、`tools`、`todo`、`limits`、`mode`。`show.taskProgress` 控制顶部的 `Tasks 0/4`；Context 行始终保留 `75k/258.4k` 形式的当前/总 token，`show.tokenBreakdown` 控制额外的 `in/out/cached` 明细。`show.reasoning` 会把推理强度加入模型方括号；设置 `NO_COLOR=1` 可关闭 ANSI 颜色。

运行时变量：

| 变量 | 默认值 | 范围/说明 |
| --- | --- | --- |
| `CODEX_CUSTOM_STATUSLINE_INTERVAL_MS` | `1000` | 刷新间隔，250-60000 ms |
| `CODEX_CUSTOM_STATUSLINE_TIMEOUT_MS` | `350` | 单次渲染超时，50-5000 ms |
| `CODEX_CUSTOM_STATUSLINE_MAX_LINES` | `6` | 最多显示 1-8 行 |
| `CODEX_HUD_CONFIG` | 用户配置路径 | 使用另一份 JSON 配置 |
| `CODEX_HUD_RENDERER` | 内置 renderer | 使用自定义可执行渲染器 |

自定义渲染器会直接执行，不经过 shell。它从 stdin 接收版本化 JSON 快照，并把 UTF-8/ANSI 文本写到 stdout。超时或失败时，Codex 保留上一次成功的渲染结果。

## 更新

```bash
~/.local/share/codex-hud/scripts/install.sh
```

更新同样下载最新预编译 Release，不会重新构建，用户配置不会被覆盖。由于补丁固定上游版本，项目维护者升级 Codex 时需要先更新并重新验证 `patches/` 中的补丁，不能只修改版本号。

## 卸载

删除命令和运行文件，但保留用户配置：

```bash
~/.local/share/codex-hud/scripts/uninstall.sh
```

同时删除 `~/.config/codex-hud`：

```bash
~/.local/share/codex-hud/scripts/uninstall.sh --purge
```

## 开发与验证

```bash
node --test renderer/statusline.test.mjs
sh -n bin/codex-hud scripts/*.sh

./scripts/prepare-upstream.sh
cd .cache/codex/codex-rs
cargo test -p codex-tui custom_status_line
```

## 常见问题

`codex-hud: command not found`：确认 `~/.local/bin` 已加入 `PATH`。

安装返回 404：该平台尚无预编译 Release；按“从源码构建”章节安装，或等待对应平台发布。

源码构建进程被系统终止：通常是内存或磁盘不足。减少并行数，例如 `CODEX_BUILD_JOBS=2 ./scripts/build.sh`，并检查 swap 和剩余空间。

补丁无法应用：删除项目内的 `.cache/codex` 后重试。不要把 `CODEX_HUD_SOURCE_DIR` 指向其他 Codex 版本。

HUD 不刷新：检查 `node --version`，并确认 `~/.config/codex-hud/config.json` 是合法 JSON。

## License

Apache-2.0。本项目包含对 [OpenAI Codex](https://github.com/openai/codex) 的修改，保留上游 `LICENSE` 和 `NOTICE`。
