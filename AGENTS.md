# ProxyAll 项目总览

- `proxyall` 安装 `sb.sh`、`deploy.sh` 和统一入口。`sb.sh` 管理 Xray 入站、出站、配置事务、服务和链接；`deploy.sh` 管理 Emby/Nginx、证书及 HTTPS 分流。`advanced_relay.sh`、`parser.sh` 含旧版兼容代码；`ssrust.sh` 是独立脚本。
- 共享 443 时 HAProxy 按 SNI 分流：Emby 和 XHTTP TLS 共用 Nginx，Reality 由 Xray 握手。配置集中在 `/usr/local/etc/sing-box/`。操作节点沿用 `_node_operation` 的候选配置、校验和回滚。
- 用户使用最新 mihomo Alpha，通过 Sub-Store 转换。创建、查看节点时交付完整分享链接，无需贴 YAML；内部 `clash.yaml` 仍用于节点管理。改导出时同时检查创建、改端口、查看和聚合订阅。
- 引入新协议或首次使用某字段前，用实际分享链接跑 Sub-Store 原生解析 → Clash.Meta/mihomo 导出，逐字段核对值、类型和嵌套，并记下 Sub-Store 版本与 mihomo Alpha 构建。丢字段或客户端不支持时告诉用户具体影响；原链接仍保留全部必要参数。SS 的 `smux` 有专用 `substore-smux.js`。
- 针对改动运行 `python3 tests/<主题>.py`。Reality 导入/握手看 `protocol_import.py`，XHTTP 配置/证书/流量看 `xhttp*.py`，VLESS ENC 的密钥配对及导出看 `vless_encryption.py`，无 TLS TCP ENC 与 mihomo 链式连接看 `vless_tcp_encryption.py`，交互取消看 `interaction.py`，节点参数编辑、证书修复、SS2022 密钥与修改后流量看 `node_edit.py`；安装与哈希看 `installer.py`。真实回环测试的 `TEST_*` 二进制见 `README.md`；区分跳过、预期拒绝和连接成功。
- 修改配套脚本时按 `parser.sh` → `advanced_relay.sh` → `sb.sh` → `proxyall` 的依赖顺序更新 SHA-256；`deploy.sh` 单独由 `proxyall` 固定。同步组件版本及 `CHANGELOG.md`，用 `pa_validate_bundle` 检查整套文件。
