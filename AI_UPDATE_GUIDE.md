# ProxyAll AI 维护指南

## 每次开始工作前

新接手项目的 agent 先读完本指南，再按以下步骤确认本次工作的起点。

1. 运行 `git rev-parse --show-toplevel`，核对仓库的绝对路径。本机默认维护 `/mnt/shared/codex/proxyall/ss_node`。即使两个副本的提交号相同，也要确认当前目录是本次任务指定的副本。
2. 用 `git remote get-url origin` 确认远端是 GitHub 的 `KevinChen222/ss_node`，再运行 `git fetch origin`。成功后用 `git rev-parse HEAD origin/main` 比较本地和 GitHub 主线的完整提交号。
3. 运行 `git status --short --branch` 检查分支及已暂存、未暂存和未跟踪的文件。日常主线维护应从正确目录、`main` 分支和相同提交开始。有差异时，先用 `git log --left-right --oneline HEAD...origin/main` 和 `git diff HEAD` 查清本地工作，保留现有改动，确认本次基线后再编辑。

## 组件

`proxyall` 按同一 Git 提交下载五个文件。`proxyall`、`sb.sh`、`deploy.sh` 安装为 `proxyall`、`sb` 和 `nginxproxy`。`lib/common.sh` 提供配置写锁等共用函数，`lib/sni_router.sh` 管理共享 443 的路由状态、HAProxy 配置和失败恢复。两个库安装在 `/usr/local/lib/proxyall/`，由两个管理入口加载。`sb.sh` 管理 Xray 节点、出站和分享链接，`deploy.sh` 管理 Nginx、Emby 反代和证书。旧菜单的 `_advanced_features` 按固定哈希加载 `advanced_relay.sh` 和 `parser.sh`。`archive/` 存放独立历史工具，仅在明确维护归档工具时读取。

## 配置与共享 443

- 配置位于 `/usr/local/etc/sing-box/`。节点变更沿用 `_node_operation`：先收集输入，在第一次写入前用 `_node_tx_begin` 获取配置锁并核对快照，再校验、发布候选配置。取消或无变更直接返回，发布失败恢复受影响的文件与服务。
- 同时操作节点和 SNI 路由时，先取配置写锁，再取路由锁。HAProxy 按 SNI 将 Emby 和 XHTTP TLS 转给 Nginx，将 Reality 转给 Xray。共享状态和渲染规则统一改 `lib/sni_router.sh`，用 `tests/sni_router.py` 覆盖两个入口。`sb` 不可用时，`nginxproxy` 通过同一个库登记或移除自己的 HTTPS 路由，保留已有 Reality 和独立 TLS 路由。
- `clash.yaml` 用于内部节点管理。用 `yq` 读写节点名称时使用 `strenv()`，保证 `443`、`true` 等名称仍为字符串。

## 分享链接与验证

创建和查看节点时交付完整分享链接。修改协议字段或导出逻辑时，检查创建、改端口、查看、聚合订阅四条路径。把实际链接交给 Sub-Store 原生解析，再导出 Clash.Meta 并用 mihomo Alpha 验证字段值、类型和嵌套。记录两个工具的版本，说明丢字段对客户端的影响，在原链接中保留必要参数。SS 多路复用由 `substore-smux.js` 配合转换。

按改动运行 `python3 tests/<主题>.py`。事务与取消看 `transactions.py`、`interaction.py`，端口与共享路由看 `port_edit.py`、`sni_router.py`，节点编辑和证书看 `node_edit.py`。XHTTP 流量看 `xhttp.py`、`xhttp_reality_traffic.py`，Reality 导入看 `protocol_import.py`，VLESS ENC 看 `vless_encryption.py`、`vless_tcp_encryption.py`。真实回环用例所需的 `TEST_*` 变量见各测试文件。报告时区分连接成功、预期拒绝和跳过。

## 发布

每次更新收尾时，对照本次变更逐节复核本指南。凡是会影响下一位 agent 开工、修改、验证或发布的内容，都要合并到对应章节，替换过时的路径、命令和约定，并随本次变更一起提交。指南描述当前仓库可验证的做法，版本变更记录写入 `CHANGELOG.md`。

从三文件安装升级时，第一次 `proxyall --update` 使用旧清单，并调用已替换的 `sb setup-maintenance`。新版入口须在库缺失时仍能打开更新菜单。第二次从菜单更新会校验并补齐两个库。修改加载流程、安装清单或维护命令时，运行 `python3 tests/installer_upgrade.py` 重走两步更新，运行 `python3 tests/common.py` 验证旧安装器调用实际维护命令。后者用 `bwrap` 隔离系统路径。

同步受影响组件的版本和 `CHANGELOG.md`，对每个改动的 Shell 脚本运行 `bash -n`。运行 `python3 tools/component_pins.py --write` 刷新依赖哈希，再运行 `python3 tools/component_pins.py` 和 `python3 tests/installer.py` 验证发布包。推送后用 `git ls-remote origin refs/heads/main` 核对远端提交。
