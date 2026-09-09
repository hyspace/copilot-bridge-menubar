# Copilot Bridge Menu Bar

Native **Apple Silicon macOS menu-bar app** for [hyspace/copilot-bridge](https://github.com/hyspace/copilot-bridge).
MIT licensed. No Dock icon, no normal application window, no end-user Bun installation.

原生菜单栏 App：管理 Copilot Bridge、GitHub 设备授权、token 用量和剩余 credits。
**不会修改 Codex/Claude 配置，不会接管或终止你原来运行的 CLI。**

![菜单栏面板预览](docs/screenshots/overview.png)

## 安装

```sh
brew tap hyspace/copilot-bridge-menubar https://github.com/hyspace/copilot-bridge-menubar
brew install --cask hyspace/copilot-bridge-menubar/copilot-bridge-menubar
```

要求 macOS 14+、Apple Silicon。安装后在「应用程序」中打开 **Copilot Bridge**。
App 位于 `/Applications/Copilot Bridge.app`。首次打开默认不启动后端，点击菜单栏图标 →「启动服务」。
已占用的端口只会显示提示；**如果原有 CLI 正在 4142 运行，请先给 App 选择其他端口**。

如果 Homebrew 在添加 tap 时提示未信任，先运行
`brew trust --cask hyspace/copilot-bridge-menubar/copilot-bridge-menubar`，再重试安装。

也可以下载 Release 的 `Copilot-Bridge-arm64.zip`，解压后把 App 放到 Applications。
默认公开构建使用 ad-hoc 签名，不宣称已获 Apple Developer ID 签名/公证。
如果 Gatekeeper 阻止从浏览器下载的副本，可自行从源码构建，或在确认来源后按 macOS 的
“隐私与安全性 → 仍要打开”流程处理；本项目不会自动关闭 Gatekeeper 或删除隔离属性。

更新前先退出 App，再运行：

```sh
brew update
brew upgrade --cask hyspace/copilot-bridge-menubar/copilot-bridge-menubar
```

需要开机运行时，在 App 设置中启用「登录 macOS 时打开 App」；
是否自动启动后端由「打开 App 时启动服务」单独控制。

## 功能

- 菜单栏概览 / 设置 / 日志三个页面，无 Dock 图标或普通窗口。
- 仅本机 `127.0.0.1` 或局域网 `0.0.0.0`，自定义非特权端口。
- 启动、停止、重启自己的子进程，端口占用检测，不使用 `killall` / `pkill`。
- GitHub 设备登录；复用 CLI 缓存，换取并自动刷新 Copilot token。
- 今日 / 累计输入、输出、缓存 tokens、请求、错误、缺失 usage 次数。
- 直接查询 GitHub `/copilot_internal/user` 的剩余额度；识别新版 token-based credits，
  不把旧版 premium interactions 当成美元或新版 credits。
- 生成 Codex 参考配置，仅复制到剪贴板，不改写任何用户配置。
- 模型覆盖、Auto 模式、请求间隔、限流等待、debug、账号类型和代理配置。
- 界面中文；发行包包含 Bun 编译的独立后端，用户无需安装 Bun、Node 或 npm。

## 与原启动命令的关系

默认等价于：

```sh
env -u COPILOT_TOKEN -u COPILOT_BASE_URL copilot-bridge start \
  --host 127.0.0.1 --port 4142 \
  --no-codex-setup --no-claude-setup --no-prompt
```

`copilot-bridge` 在 App 中由内置独立可执行文件代替，不调用用户 shell 或修改 PATH。
`COPILOT_TOKEN` 不继承，让 CLI 使用 GitHub 缓存获取并刷新 token。
自定义上游默认为空，只有主动填写时才设置 `COPILOT_BASE_URL`。

所有 CLI 选项的对应关系与有意固定的安全选项见 [CLI 选项表](docs/cli-options.md)。

## Codex

点击「复制 Codex 参考配置」，手动合并到 `~/.codex/config.toml`，不要整体覆盖。
默认保留：

```toml
[model_providers.bridge]
name = "Copilot Bridge"
base_url = "http://127.0.0.1:4142/v1"
wire_api = "responses"
supports_websockets = false
requires_openai_auth = true
```

App 不使用无效的 provider 字段 `prefer_websockets`。
如果未设置模型覆盖，生成的 `model` 是明确的占位符，需要换成你有权限使用的模型。

## 局域网安全

局域网模式不需要 key，也不需要额外认证头。切换后监听 `0.0.0.0`，
同一网络里的设备可以通过此 Mac 的地址与端口访问。

**仅在可信内网使用。HTTP 未加密且没有入站鉴权，不要暴露到公网或做端口转发。**

## 用量和数据

- 只统计本 App 处理的上游请求；无法补算以前 CLI 的 token 使用量。
- 只提取模型实际返回的 usage，不估算 tokens。缺少 usage 会单独显示，不伪装为零。
- 缓存 tokens 属于输入的一部分，不能重复相加。重试和内部搜索请求按实际上游请求计数。
- credits 是 GitHub API 的原始单位，不做没有依据的货币换算。
- GitHub 内部额度接口不是稳定公开契约；字段缺失显示“未知”，而不是零。
- 聚合数据库保留 730 天；去重 ID 保留 2 天。没有对话正文数据库。
- 日志每份约 2 MB，保留 3 份历史；界面只保留最近 200 行。
- `--debug` 的上游错误文本可能含服务端返回的业务信息；分享日志前仍须检查。

数据位置：

```text
~/Library/Application Support/CopilotBridgeMenuBar/
  settings.json       # App 设置，不含账号凭据
  usage.sqlite        # 每日/模型聚合，不含提示词或输出
  Logs/bridge*.log    # 有限轮转日志
~/.local/share/copilot-bridge/github_token  # CLI 自己维护，权限 0600
```

## 开发

```sh
git clone --recurse-submodules https://github.com/hyspace/copilot-bridge-menubar.git
cd copilot-bridge-menubar
cd vendor/copilot-bridge && bun install --frozen-lockfile && cd ../..
bun test backend
swift test --disable-sandbox
python3 scripts/test-cask.py
python3 scripts/build-backend.py
python3 scripts/test-auth.py
python3 scripts/integration-test.py
bash scripts/build-app.sh
```

构建依赖：Apple Silicon Mac、Xcode/Command Line Tools（Swift 6+）、Python 3、Bun 1.4.1。
Swift 包没有第三方远程依赖。底层 fork 通过 Git submodule 固定提交，JS 依赖由其 `bun.lock` 固定。
健康标识、token 观测、认证和流式修复都在固定的 CLI fork 提交中；本仓库只复制源码进行打包，**不做构建时源码补丁，也不重启现有 CLI**。

测试只使用假的 GitHub/Copilot 上游、临时 HOME、随机非 4142 端口。
测试前后校验当前 4142 监听进程不变，不读取真实凭据、不消耗真实模型额度。
原生测试还覆盖菜单 App 的启动/停止、授权成功收尾、崩溃重试断路器、
强制停止不响应 SIGTERM 的**测试子进程**，以及本 App 视图的离屏渲染。

更多：[架构](docs/architecture.md) · [发布](docs/releasing.md) · [贡献](CONTRIBUTING.md) · [安全](SECURITY.md)

## License

MIT © 2026 hyspace. The pinned CLI is MIT © betaHi and contributors.
Bundled runtime/dependencies retain their own licenses; see `THIRD_PARTY_NOTICES.md`
and the license files packaged in the app.
