# CLI 参数覆盖

| CLI 选项 | App 中的对应 |
| --- | --- |
| `start --host` | 仅本机 / 局域网 |
| `start --port` | 1024–65535 端口字段 |
| `--model` | 模型覆盖；空值省略参数，保留客户端选模 |
| `--debug` | 调试日志开关 |
| `--rate-limit` | 请求间隔；0 表示不设置 |
| `--wait` | 达到间隔限制时等待 |
| `--auto` | Auto 模式开关 |
| `--codex-setup` | 固定禁用：符合“不自动替换 Codex 配置”的产品约束 |
| `--claude-setup` | 固定禁用：当前只面向 Codex |
| `--prompt` | 固定禁用：无交互式终端；由 App 或 Codex 的模型设置替代 |
| `--show-token` | 不启用：它会把真实 token 输出到日志，不适合常驻 App |
| `auth` | GitHub 登录 / 重新授权按钮 |
| `auth --host/--port` | 使用当前端口及 loopback 配置初始化，不开额外认证监听端口 |
| `auth --show-token` | 同样不启用 |

环境选项：
`COPILOT_ACCOUNT_TYPE`、可选的 `COPILOT_BASE_URL`、`COPILOT_VSCODE_VERSION`、
HTTP(S) 代理和 `NO_PROXY` 有对应设置。
`COPILOT_TOKEN`、运行时 loader 环境和原始请求 trace 目标被有意清除。
这不是任意 shell 命令执行器，也不允许注入额外任意 CLI 参数。
