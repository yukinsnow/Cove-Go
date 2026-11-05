# Native conversation cache / 原生会话缓存

原生 OpenClaw 和 DSH 远程页面优先读取本机快照，连接和刷新在后台进行。仅缓存访问过的历史；首次加载和发送消息仍需联网。WebView 模式不在本次范围内。

- OpenClaw：启动恢复列表、最近打开的会话和已读取历史；切换会话立即显示已有历史，再读取服务器。恢复前台时刷新或重连。手动连接优先于尚未完成的启动恢复。
- DSH：持久保存按主机身份、工作区隔离的抽屉列表；聊天缓存为最近 150 个条目中的已完成文字消息，不恢复工具执行、附件文件、审批或未发送操作。服务器快照仍是操作权限的唯一来源。
- 快照使用 AES-GCM 加密，密钥保存在平台安全存储，磁盘文件名为摘要。最多 24 份内容快照，另保留最多 8 份账号绑定摘要，每份明文上限 2 MiB；旧快照被淘汰。损坏或读取失败时退回正常网络加载。
- 缓存不是备份，也不证明远程主机在线。未连接时不发送消息、执行工具或处理审批。

The native OpenClaw and remote DSH pages display saved snapshots before connecting or refreshing. Only previously fetched history is available offline; the first fetch and sending still require a connection. WebView mode is outside this change.

OpenClaw restores the session list, last selection and fetched histories, then updates them in the background. Resuming refreshes or reconnects; explicit connection choices take precedence over late startup restoration. DSH drawer snapshots retain host/workspace identity isolation; its chat snapshots contain completed text among the most recent 150 items, not tool execution, attachment files, approvals or pending submissions. Live snapshots remain authoritative for controls.

Snapshots use AES-GCM with a platform-secure key and digest filenames. Storage is bounded to 24 content snapshots plus eight account-binding digests and 2 MiB plaintext per snapshot, evicting older writes. Missing, corrupt or inaccessible caches fall back to network loading. This is a display cache, not a backup or proof of connectivity.
