# ProxyAll AI 维护指南

## 工作目录与组件

从 `ss_node/` 仓库根目录运行 Git 和测试命令。开始维护前用 `git rev-parse --show-toplevel` 确认目录，用 `git fetch origin` 和 `git status -sb` 核对当前分支与 GitHub 主线。

`proxyall` 从同一提交下载三个脚本，校验后安装为 `proxyall`、`sb` 和 `nginxproxy`。`sb.sh` 管理 Xray 节点、出站和分享链接，`deploy.sh` 管理 Nginx、Emby 反代和证书。旧菜单的 `_advanced_features` 按固定哈希加载 `advanced_relay.sh` 和 `parser.sh`。`archive/` 存放独立历史工具，仅在明确维护归档工具时读取。

## 配置与共享 443

- 配置位于 `/usr/local/etc/sing-box/`。节点变更沿用 `_node_operation`：先收集输入，在第一次写入前用 `_node_tx_begin` 获取配置锁并核对快照，再校验、发布候选配置。取消或无变更直接返回，发布失败恢复受影响的文件与服务。
- 同时操作节点和 SNI 路由时，先取配置写锁，再取路由锁。HAProxy 按 SNI 将 Emby 和 XHTTP TLS 转给 Nginx，将 Reality 转给 Xray。改动要兼容已有独立 TLS 路由。`sb` 不可用而状态含 `tls_routes` 时，`deploy.sh` 应拒绝改写并保留前端。
- `clash.yaml` 用于内部节点管理。用 `yq` 读写节点名称时使用 `strenv()`，保证 `443`、`true` 等名称仍为字符串。

## 分享链接与验证

创建和查看节点时交付完整分享链接。修改协议字段或导出逻辑时，检查创建、改端口、查看、聚合订阅四条路径。把实际链接交给 Sub-Store 原生解析，再导出 Clash.Meta 并用 mihomo Alpha 验证字段值、类型和嵌套。记录两个工具的版本，说明丢字段对客户端的影响，在原链接中保留必要参数。SS 多路复用由 `substore-smux.js` 配合转换。

按改动运行 `python3 tests/<主题>.py`。事务与取消看 `transactions.py`、`interaction.py`，端口与共享路由看 `port_edit.py`、`sni_router.py`，节点编辑和证书看 `node_edit.py`。XHTTP 流量看 `xhttp.py`、`xhttp_reality_traffic.py`，Reality 导入看 `protocol_import.py`，VLESS ENC 看 `vless_encryption.py`、`vless_tcp_encryption.py`。真实回环用例所需的 `TEST_*` 变量见各测试文件。报告时区分连接成功、预期拒绝和跳过。

## 发布

同步受影响组件的版本和 `CHANGELOG.md`，对每个改动的 Shell 脚本运行 `bash -n`。运行 `python3 tools/component_pins.py --write` 刷新依赖哈希，再运行 `python3 tools/component_pins.py` 和 `python3 tests/installer.py` 验证发布包。推送后用 `git ls-remote origin refs/heads/main` 核对远端提交。
