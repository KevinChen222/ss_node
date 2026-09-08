# Mihomo 管理器 2.0

`mh.sh` 保持单文件发布，内置节点构建、分享链接解析和中转管理。无需额外下载新的解析脚本。沿用 `/usr/local/etc/mihomo/config.yaml`、`clients.yaml`、`nodes.json`，保留旧节点、凭据和端口；进入菜单不会自动迁移监听端口。

## 发布和使用

将同一版本的六个发布文件一起上传到原仓库：`proxyall`、`sb.sh`、`mh.sh`、`deploy.sh`、`advanced_relay.sh`、`parser.sh`。`proxyall` 内的校验值已配套更新；不要仅上传 `mh.sh`。

现有 VPS 在 `proxyall` 主菜单选择 **4：检查脚本更新**。进入 Mihomo 后选择 **15：安装/更新核心和服务**，再使用节点向导。直接运行 `mh --help` 可查看命令行入口。脚本更新与核心更新仍是两个独立操作。

主菜单 1–17 与 `sb` 的功能位置对应，18 为导出。添加节点菜单 1–10 与 `sb` 一致，11 为批量向导，**12 为 XHTTP**。

## XHTTP

- 使用官方 Mihomo 原生 `xhttp-config` 入站；本次按 **v1.19.30** 核验，新建 XHTTP 要求该版本或更高稳定版。
- 选择直连或 CDN。TLS 默认公网 443，并可选择 HAProxy SNI 分流或独立监听；其他端口也可独立使用。
- 域名/SNI/HTTP Host 与客户端连接地址分开。连接地址可填 CDN 优选 IP，证书名称和 Host 仍使用节点域名。
- 服务端模式为 `auto`；客户端提供 `auto`、`packet-up`、`stream-up`、`stream-one`。CDN 默认 `packet-up`；其他模式需要 CDN 支持对应的流式上传和回源方式。
- 独立下行可用于共享 443 和独立端口。两个域名必须回到同一个 Mihomo 监听器；证书覆盖两个域名，服务端不固定单一 Host。
- `stream-one` 不能与独立下行组合。该组合在申请证书和提交节点前被拒绝。
- 分享链接保留 `extra.downloadSettings`，并转换为 Xray 的字段格式；解析回 Mihomo 时再转换回 `download-settings`。不同客户端对扩展链接的支持有差异，**Mihomo 客户端优先导入完整 YAML**。

例如，Emby 使用 `emby.example.com`，上行使用 `up.example.com`，下行使用 `down.example.com`。三者可共用公网 TCP 443，但完整 SNI 域名不能相同。共享端口时 HAProxy 只做 TCP 分流，TLS 由各自的后端处理。

自动证书继续调用 `sb` 的 Nginx/ACME webroot 接口，复用原有续期机制。CDN 设置需允许 HTTP-01 验证路径，并对节点路径关闭缓存、重定向和质询。

## 其他功能

| 范围 | 实现 |
|---|---|
| 入站 | VLESS Reality/TCP/WS/gRPC/XHTTP、Trojan WS、AnyTLS、HY2、TUIC、SS、SOCKS5 |
| Reality | 复用 `sb` 扫描/自有 HTTPS 源站向导；保留手动输入；检测握手回环和 TLS 1.3 |
| SS | AES-256-GCM、ChaCha20-Poly1305、SS2022 AES-128/256、Multiplex + Padding；按加密方式生成正确长度密钥 |
| HY2 跳跃 | 独立 nftables 表，范围冲突检查、原子规则更新、开机恢复；改端口/删节点时同步维护 |
| TLS | 自动证书、已有证书、直连自签证书；验证有效期、域名、证书与私钥匹配 |
| 端口 | 随机空闲端口；TCP/UDP 分别检查；UDP 443 可与 TCP 443 并存；修改时同步客户端和 SNI 路由 |
| 中转 | 按编号选择本机入站，绑定外部出站；解除映射时保留本机节点 |
| 导入 | VLESS、VMess、Trojan、AnyTLS、SS、SOCKS5、HY2、TUIC；也可用 `file:/绝对路径.yaml` 从完整 YAML 中选择节点 |
| 转发 | Mihomo 原生 tunnel 监听器，支持 TCP、UDP、二者同时透传；无需修改系统 NAT 规则 |
| Argo | 独立的 Mihomo VLESS WS 临时/固定隧道；系统服务守护；每分钟同步临时域名、重启、日志和关联删除 |
| 服务 | systemd/OpenRC 安装、启动、停止、重启、状态、日志、每日定时重启、系统时间同步 |
| 维护 | DNS 配置、链接/YAML 导出、批量逐节点向导、配置检查、核心升级和卸载备份 |

批量模式逐个执行独立向导，失败不会删除已经成功创建的节点。临时 Argo 隧道域名在进程重启后可能变化；后台任务每分钟同步一次，管理菜单持锁期间后台任务跳过，查看/导出节点时也会同步。Argo 菜单 **5** 手动同步当前域名，**3** 重启后同步；同步客户端地址不重启 Mihomo。固定 Token 隧道不需要变更域名。固定隧道的 Public Hostname 需要在 Cloudflare 配置为向导显示的本机 HTTP 后端。

内核差异：Mihomo v1.19.30 的 AnyTLS 入站没有 `reality-config` 字段，因此没有提供会被内核忽略的 AnyReality 选项。可使用 AnyTLS + TLS 或 VLESS + Reality。SS Padding 的客户端 smux 参数保存在 YAML 中，普通 SS 分享链接无法表达这些参数。

## 可靠性修复

1. 配置使用 JSON/YAML 结构化写入，节点名、密码、路径中的引号不会变成配置语法。
2. 修正旧版删除节点中不受 mikefarah/yq v4 支持的 `if … then` 表达式。
3. 主菜单在独立子进程执行操作，保留 Bash 的错误退出语义；失败返回菜单，不继续执行失败语句后的写操作。
4. 配置提交前校验服务端、客户端和元数据的名称/端口/映射一致性；文件提交或服务启动失败时恢复旧状态，恢复失败保留材料。
5. 从配置中实际引用的证书文件生成 `SAFE_PATHS`。systemd 使用受管理的环境文件及 drop-in，OpenRC 显式导出环境变量；没有关闭 Mihomo 的路径检查。
6. 重启后检查监听端口及进程归属。Mihomo 的 `-t` 不足以证明证书能在运行时打开，也不足以证明入站真的启动。
7. OpenRC 的后台进程不继承管理会话文件锁。卸载先保存原配置，节点删除复用共享证书的引用检查。

## 验证

测试脚本只操作临时目录。需要 Bash、jq、mikefarah/yq v4、OpenSSL、官方 Mihomo，以及 Python 3（仅运行端到端测试）。

```bash
test_dir=$(mktemp -d)
MH_TEST_ROOT="$test_dir" MH_TEST_BIN=/usr/local/bin/mihomo bash tests/mh_regression.sh
python3 tests/mh_xhttp_e2e.py --mihomo /usr/local/bin/mihomo --fixtures "$test_dir"
python3 tests/check_release.py
```

本次在 Windows 上使用 Git Bash、官方 Mihomo **v1.19.30**、yq **v4.53.6**、jq **1.8.2** 运行。回归测试模拟了服务管理、nftables 命令及 SNI API，验证配置生成、端口迁移、失败回滚、删除、中转、转发、跳跃规则更新和 Argo 域名同步。端到端测试实际启动两个 Mihomo 进程，通过本机 HTTP 服务验证上传和下行响应：9 个 XHTTP 场景及其他 11 个协议配置，合计 **20 个场景**，各传输两次 2.1 MB 并校验 SHA-256；Reality 使用额外的本机 TLS 1.3 源站。

当前环境没有可用的 Linux/systemd/OpenRC，也未连接实际 VPS，因此 HAProxy、ACME 公网签发/续期、CDN、Argo 公网链路、nftables 内核转发及操作系统服务安装还需要在 VPS 上验收；本机测试不等于这些外部环境已经验证。

实现依据：[Mihomo VLESS 入站](https://wiki.metacubex.one/config/inbound/listeners/vless/)、[传输层参数](https://wiki.metacubex.one/config/proxies/transport/)、[SAFE_PATHS](https://wiki.metacubex.one/en/config/general/)、[Cloudflared 运行参数](https://developers.cloudflare.com/tunnel/advanced/run-parameters/)。
