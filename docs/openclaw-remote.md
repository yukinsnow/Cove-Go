# Cove-Go：双后端远程客户端

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

## 外观与小伙伴

在任一协议的设置中选择日间、夜间或跟随系统；选择保存在设备上并同时应用到两个协议。夜间采用深蓝灰渐变、柔和浅蓝控件和近黑代码块。DSH 原生对话显示原创像素小鲸鱼，OpenClaw 原生对话显示原创像素小龙虾，分别有独立的显示开关并记住选择；点击可轻跳，跟随输入栏或状态条移动。系统减少动态效果时不播放跳动。内嵌网页不注入宠物。原版 Deepy/鲸娘素材仍不打入衍生版。

## iOS 构建

macOS + Xcode + Flutter 3.47.9：

```sh
bash tooling/build-openclaw-ipa.sh
```

输出 `build/openclaw/Cove-Go-0.1.14-build15-<提交号>-unsigned.ipa`，需要自己的签名/安装流程。
仓库的 `Build Cove-Go iOS` workflow 仅上传构建 Artifact，不创建 Release。
Linux 上不能运行 Xcode 或证明 iPhone 实机可用。

## 当前尚未完成的集成

- OpenClaw 原生工具审批/提问面板、语音、内联 widget 与设备能力调用。
- OpenClaw 历史分页（当前读取最近 150 条）。
- DSH 功能在 iOS 真机上的端到端验收；安卓本机运行、无障碍手机操控不属于 iOS 远程能力。
- 构建入口已换用确认的海洋终端图标（D9 配色＋D14 海浪），禁用原品牌与原版桌宠并从 IPA 中排除对应素材；新的小伙伴为独立绘制；原 DSH 开发入口不变。详见 `ASSETS.md`。

## 验证

```sh
(cd packages/openclaw_client && dart pub get && dart analyze && dart test)
(cd app && flutter analyze lib/main_openclaw.dart lib/openclaw test/openclaw)
(cd app && flutter test test/openclaw test/remote/relay_backend_test.dart)
python3 app/tool/l10n_merge.py --check
```

协议单测使用本地模拟 Gateway，不连接用户的真实会话、不自动批准设备、不产生模型费用。

## 多 OpenClaw 主机与关于

- 远程主机页始终提供“添加 OpenClaw 主机”和“通过 SSH 添加 OpenClaw 主机”。每个 Gateway 各自保存令牌、设备身份、SSH 隧道、历史与草稿；原生页面切换不主动断开其他 Gateway。iOS 挂起时仍不保证后台长连接。
- 旧的单 Gateway 配置会复制到安全存储中的 `legacy` 主机，目录提交成功后才清理旧键。设备身份沿用，避免无故重新配对；新增主机使用独立身份。
- OpenClaw 与 SSH 行左滑可露出右侧删除，或长按打开删除菜单；操作仍需确认。只删除手机上的对应连接，不删除服务器或对话。DSH Remote 没有原生删除接口，手势引导到控制台执行真实管理，不伪造本地删除。
- 设置中的“关于 Cove-Go”显示构建版本、项目主页、作者，以及原 DSH Go 项目和作者，可点击链接在浏览器打开。

## 图片恢复与输入键盘

- 历史图片读取消息块、`openclawDisplayContent` 与 `__openclaw.media`。`media://inbound` 通过当前 Gateway 的认证媒体接口读取；托管输出图片重新申请下载凭证，不复用过期地址。SSH 连接沿用当前隧道。
- 旧 Gateway 回账只返回文字时，已发送图片保留为显示专用回退；刷新、切换会话后继续使用，并受原有按主机隔离的加密快照预算限制（每个快照 2 MiB，最多 20 个历史会话）。这不是完整相册备份；旧版已丢失、服务端也没有媒体引用的图片无法凭空恢复，大图回退也可能因缓存预算被淘汰。
- OpenClaw 和 DSH 的附件入口在打开菜单或系统相册前显式收起键盘；选择期间切换主机/会话仍会废弃旧选择。
- 两端设置中的“换行键发送”默认关闭。打开后软件键盘显示发送动作；中文候选输入、未连接、提交中等状态不会误发送，硬件 Shift+Enter 保留换行。选择持久保存在本机，独立于硬件 Enter 设置。

这些行为由模拟 Gateway、widget 与加密快照测试覆盖，不能替代 iPhone 真机键盘/相册验证。

## Cove-Go 品牌

产品名称统一为 `Cove-Go`，不使用中文别名。图标采用 D9 深海配色＋D14 海浪。仅变更显示品牌；现有 GitHub 仓库地址、iOS Bundle ID、Gateway 协议 client ID、设备身份和安全存储键保持不变，以保留安装与配对连续性。原 DSH Go 项目署名保留。
