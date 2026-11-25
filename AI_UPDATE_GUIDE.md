# ProxyAll AI 维护指南

## 每次开始工作前

新接手项目的 agent 先读完本指南，再按以下步骤确认本次工作的起点。

1. 运行 `git rev-parse --show-toplevel`，核对仓库的绝对路径。本机默认维护 `/mnt/shared/codex/proxyall/ss_node`。即使两个副本的提交号相同，也要确认当前目录是本次任务指定的副本。
2. 用 `git remote get-url origin` 确认远端是 GitHub 的 `KevinChen222/ss_node`，再运行 `git fetch origin`。成功后用 `git rev-parse HEAD origin/main` 比较本地和 GitHub 主线的完整提交号。
3. 运行 `git status --short --branch` 检查分支及已暂存、未暂存和未跟踪的文件。日常主线维护应从正确目录、`main` 分支和相同提交开始。有差异时，先用 `git log --left-right --oneline HEAD...origin/main` 和 `git diff HEAD` 查清本地工作，保留现有改动，确认本次基线后再编辑。

## 组件

日常客户端为 `sing-box`（含 `sing-box refine`，直接兼容原有 mihomo 订阅格式并配合 Sub-Store），服务端以 `sing-box` 为主力核心，负责 VLESS Vision + Reality、AnyTLS / Any-Reality 及其他所有非 XHTTP 节点（Hysteria2、TUICv5、Shadowsocks、WS/gRPC、裸 VLESS TCP、SOCKS5 等）、Argo、分享链接与中转；独立 `Xray` 备用核心仅用于创建与维护两种 XHTTP 节点（VLESS XHTTP + TLS / H2 与 VLESS XHTTP + Reality），不向 Xray 扩展非 XHTTP 协议。

`proxyall` 按同一 Git 提交下载五个文件：`proxyall`、`sb.sh`、`deploy.sh` 安装为 `proxyall`、`sb` 和 `nginxproxy`；`lib/common.sh` 提供配置写锁等共用函数，`lib/sni_router.sh` 管理共享 443 的路由状态、HAProxy 配置和失败恢复，两个库安装在 `/usr/local/lib/proxyall/` 并由两个管理入口加载。`deploy.sh` 管理 Nginx、Emby 反代和证书。主菜单的 `_advanced_features` 按固定哈希加载 `advanced_relay.sh` 和 `parser.sh`。`archive/` 存放独立历史工具，仅在明确维护归档工具时读取。

## 配置与共享 443

- 配置位于 `/usr/local/etc/sing-box/`：`config.json` 与 `relay.json` 为 sing-box 主配置与中转配置，`xray.json` 用于 Xray 备用核心（新建仅限两种 XHTTP 入站，同时兼容查看、改端口、删除与卸载升级保留的历史 Xray 原生节点），`metadata.json` 与 `clash.yaml` 为统一节点元数据与客户端配置。单节点与批量创建均沿用单次 `_node_operation` 事务：先收集输入（`NODE_UI=true` 时输入 `0` 或 EOF 取消，不触发写入或服务重启），首次写入前由 `_node_tx_begin` 获取配置锁并核对快照，再校验双核心配置、统一发布候选配置并单次重启服务；发布失败时恢复受影响文件、Nginx 配置、nftables、HAProxy 与服务，清理 `$NODE_TX_DIR/created-files` 记录的新建自签证书，并禁止输出分享链接。直接启动或重载守护进程及 ACME 钩子时必须关闭锁描述符（`8>&- 9>&-`），避免子进程继承写锁或路由锁。
- 交互与双核共存：创建（含批量）及实际落盘修改节点展示分享链接后，在事务锁外等待用户按回车再返回（`0`/EOF 取消直接返回不暂停），避免清屏丢失链接。纯 sing-box 或纯 Xray 主机互不强依赖另一核心，也不生成对方空配置；统一状态汇报同时覆盖两个已安装核心；卸载需一并清理重启定时器、logrotate 与两核心的 systemd 日志 drop-in（含仅安装 Xray 未建节点的场景）。
- 同时操作节点和 SNI 路由时，先取配置写锁，再取路由锁。HAProxy 按 SNI 将 Emby 和 XHTTP TLS 转给 Nginx，将 AnyTLS TLS 转给 sing-box，将默认 Reality 流量转给 sing-box（Vision / Any-Reality）或 Xray（XHTTP Reality），443 仅允许登记一个默认 Reality 后端。共享状态和渲染规则统一改 `lib/sni_router.sh`，用 `tests/sni_router.py` 覆盖两个入口。`sb` 不可用时，`nginxproxy` 通过同一个库登记或移除自己的 HTTPS 路由，保留已有 Reality 和独立 TLS 路由。
- `clash.yaml` 用于内部节点管理。用 `yq` 读写节点名称时使用 `strenv()`，保证 `443`、`true` 等名称仍为字符串。

## 分享链接与验证

- **分享链接保持原有标准链接形式，不另改格式，核心要求是不丢字段**。修改协议字段或导出逻辑时，检查创建、编辑/改端口、查看、聚合订阅四条路径。把实际链接交给 Sub-Store 原生解析，再导出 Clash.Meta 并用 mihomo Alpha 验证字段值、类型、嵌套与真实流量（与 `sing-box refine` 直接消费原有 mihomo 订阅的用法一致）；SS 多路复用仍配合 `substore-smux.js` 转换，验证报告记录实测工具版本，说明丢字段对客户端的影响，并在原链接保留必要参数。
- sing-box 主节点同时核对 sing-box 客户端连通性（Any-Reality 不在 Clash.Meta 导出范围，仅由 sing-box 客户端支持；sing-box 节点不混入 Xray 专属 VLESS `encryption`/`decryption` 或 `support-x25519mlkem768` 参数；AnyTLS 自签证书必须携带叶证书 SHA-256 `pcs` 指纹，缺指纹拒绝生成裸 `insecure=1` 链接）。两种 Xray XHTTP 节点（含可选 VLESS ENC 与 XMUX）按上述流程结合 Xray / mihomo Alpha 验证，严禁服务端 `decryption` 私钥泄露进 `clash.yaml` 或分享链接。

按改动运行 `python3 tests/<主题>.py`：事务与取消看 `transactions.py`、`interaction.py`，锁与守护进程 FD 隔离看 `common.py`，混合状态与卸载清理看 `maintenance.py`，sing-box TCP / SS2022 / ShadowTLS / AnyTLS `pcs` 看 `tcp_nodes.py`，节点名 YAML 读写看 `yaml_names.py`，端口与共享路由看 `port_edit.py`、`sni_router.py`，XHTTP 节点编辑和证书看 `node_edit.py`，XHTTP 流量看 `xhttp.py`、`xhttp_reality_traffic.py`，Reality 导入看 `protocol_import.py`，VLESS ENC 看 `vless_encryption.py`，sing-box 转发与 DNS 兼容看 `forwarding.py`、`node_dns_compat.py`。真实回环用例所需的 `TEST_*` 变量见各测试文件；报告时区分连接成功、预期拒绝和跳过。

已知上游行为：
- 官方稳定版 `sing-box 1.14.4` 缺少 X25519MLKEM768 key share 保留与 Reality 客户端版本 1.8.2 支持，连接 Xray 26.9.8+ Reality 落地时需 `1.14.5` 或更高版本（含上游提交 `39501357`、`0a03261e`）。
- Xray 26.11.9 启用 XHTTP Reality + VLESS ENC 且指向本机 Nginx 源站时，核心重启后的首个连接会因上游 `xtls/reality` 的 `DetectPostHandshakeRecordsLens` 探测引入约 5 秒冷启动延迟，触发 `mihomo Alpha` 默认 5 秒 `DialContext` 超时返回 502；缓存生效后同进程及后续连接均正常通过。

## 发布

每次更新收尾时，对照本次变更逐节复核本指南。凡是会影响下一位 agent 开工、修改、验证或发布的内容，都要合并到对应章节，替换过时的路径、命令和约定，并随本次变更一起提交。指南描述当前仓库可验证的做法，版本变更记录写入 `CHANGELOG.md`。

从三文件安装升级时，第一次 `proxyall --update` 使用旧清单，并调用已替换的 `sb setup-maintenance`。新版入口须在库缺失时仍能打开更新菜单。第二次从菜单更新会校验并补齐两个库。修改加载流程、安装清单或维护命令时，运行 `python3 tests/installer_upgrade.py` 重走两步更新，运行 `python3 tests/common.py` 验证旧安装器调用实际维护命令。后者用 `bwrap` 隔离系统路径。

同步受影响组件的版本和 `CHANGELOG.md`，对每个改动的 Shell 脚本运行 `bash -n`。运行 `python3 tools/component_pins.py --write` 刷新依赖哈希，再运行 `python3 tools/component_pins.py` 和 `python3 tests/installer.py` 验证发布包。推送后用 `git ls-remote origin refs/heads/main` 核对远端提交。
