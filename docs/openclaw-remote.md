# OpenClaw Go：双后端远程客户端

[English](openclaw-remote.en.md)

## 来源与边界

直接基于 `ccch1mneyyy/dsh-Go`（基线 `70507b00a5ed84ca21d58c5e60420fb47084f095`），
不基于 `622cc/dsh-go-ios`。原始 AGPL-3.0 及第三方署名保持不变。
新入口：`app/lib/main_openclaw.dart`。默认 DSH 入口不变。

## 同一个 App，两个协议所有者

- **DSH Remote**：保留原项目 `packages/dsh_remote`、账号浏览器登录/轮询、自托管账号、主机指纹确认、LAN/WebRTC/P2P/TURN/中继及 SSH 连接；聊天继续使用原项目原生界面。
- **OpenClaw**：新增纯 Dart `packages/openclaw_client`，直接连接 Gateway WebSocket v4；Ed25519 设备身份、挑战时间签名、RPC、会话、历史、流式文本、工具事件、模型选择、图片、排队/插话/打断。
- 通过侧栏底部主机选择器切换；“远程主机”按 OpenClaw、DSH Remote 分区；SSH 合并到各自的添加/编辑流程，OpenClaw 行内可打开连接设置与 Gateway 网页控制台，不额外占用右上角；仅在首次打开 DSH 时初始化其页面；不同连接的账号、凭据、会话与状态不会互相转换或复制。
- 这不是让 OpenClaw 模拟 DSH Remote 服务端，也不是把 DSH Remote 当成 OpenClaw 的隧道。

## 运行

```sh
cd app
flutter pub get
python3 tool/l10n_merge.py
flutter run --target lib/main_openclaw.dart --dart-define=REMOTE_DUAL_APP=true
```

OpenClaw 页面中填写 `wss://` Gateway 地址与令牌；直连远程明文 `ws://` 不接受。选择 SSH 时，可添加或复用 SSH 配置，Gateway 地址填 SSH 服务器可访问的 `ws://127.0.0.1:18789` 等地址，由加密 SSH 隧道转发；不会启动 DSH。SSH 密码/私钥仍由安全存储管理，并确认主机指纹。旧 SSH 配置默认保留在 DSH 分区，OpenClaw 专用 SSH 不出现在 DSH 切换列表。网页控制台沿用同一隧道，不在 URL 附加 Gateway 令牌。
在 Gateway 中批准首次出现的设备，再重新连接。客户端不会修改 Gateway 安全策略。
设备私钥、连接地址和凭据保存在本机系统安全存储，不写入 Git、日志或构建参数。

DSH Remote 页面使用其原有账号与主机选择。未选远程主机时打开远程主机页；
选中后进入原生 DSH 会话界面。本入口不安装或自动启动安卓本机 Linux 环境。
DSH 重连期间可立即重试，也可展开错误详情；iOS 安装包声明本地网络访问用途，首次出现授权提示时需允许访问自己的电脑。
打开、切换或重新进入 OpenClaw 会话时从最新消息开始；手动上翻历史时不因界面刷新强制跳回底部。
两个协议可以同时持有连接；这不意味着 iOS 在系统挂起后仍保证后台长连接。

## iOS 构建

macOS + Xcode + Flutter 3.47.9：

```sh
bash tooling/build-openclaw-ipa.sh
```

输出 `build/openclaw/OpenClaw-Go-0.1.10-build11-<提交号>-unsigned.ipa`，需要自己的签名/安装流程。
仓库的 `Build OpenClaw Go iOS` workflow 仅上传构建 Artifact，不创建 Release。
Linux 上不能运行 Xcode 或证明 iPhone 实机可用。

## 当前尚未完成的集成

- OpenClaw 原生工具审批/提问面板、语音、内联 widget 与设备能力调用。
- OpenClaw 历史分页（当前读取最近 150 条）、多个 Gateway 的保存列表。
- DSH 功能在 iOS 真机上的端到端验收；安卓本机运行、无障碍手机操控不属于 iOS 远程能力。
- 构建入口已换用独立网络图标，禁用原品牌与桌宠并从 IPA 中排除对应素材；原 DSH 开发入口不变。详见 `ASSETS.md`。

## 验证

```sh
(cd packages/openclaw_client && dart pub get && dart analyze && dart test)
(cd app && flutter analyze lib/main_openclaw.dart lib/openclaw test/openclaw)
(cd app && flutter test test/openclaw test/remote/relay_backend_test.dart)
python3 app/tool/l10n_merge.py --check
```

协议单测使用本地模拟 Gateway，不连接用户的真实会话、不自动批准设备、不产生模型费用。
