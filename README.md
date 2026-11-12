# ProxyAll

基于他人开源脚本整理、修改的自用版本，把 sing-box 和 Emby / Nginx 反代放进一个菜单，方便日常管理。主要按自己的使用习惯做了调整，感谢原作者的工作。

## 功能

- **节点管理**：sing-box、Xray XHTTP、Reality、SNI 自动选择、自有域名回落站点、中转及第三方节点导入。
- **反向代理**：Emby 和本机服务反代，支持多个流媒体上游。
- **共享 443**：默认通过 HAProxy 按 SNI 分流，让节点与 HTTPS 反代共用端口。
- **证书管理**：查看有效期和使用位置、检查续期、手动续期、验证在线证书、归档未使用证书。

## 安装

在 Linux VPS 上以 **root** 运行。HAProxy 共享 443 需要 systemd。

Debian / Ubuntu 如缺少基础依赖，先执行：

```bash
apt-get update && apt-get install -y bash curl ca-certificates
```

安装管理脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/KevinChen222/ss_node/main/proxyall) --install
```

安装后输入 `proxyall` 打开菜单。sing-box 核心需在其菜单中选择 **15** 安装，再选 **1** 添加节点；也可以先配置 Emby，两者没有固定安装顺序。

## 使用与更新

```bash
proxyall                 # 打开统一菜单
proxyall --update        # 检查并更新配套脚本
proxyall --certificates  # 证书管理
proxyall --swap          # 配置 1 GiB swap，保留已有启用的 swap
proxyall --fix-http2     # 修复受管 Nginx 配置的 HTTP/2 旧语法
```

| 菜单 | 功能 |
| --- | --- |
| 1 | Emby / 本机服务反代 |
| 2 | sing-box 管理 |
| 3 | 检查脚本更新 |
| 4 | 卸载统一入口，保留服务 |
| 5 | 修复 Nginx HTTP/2 旧语法 |
| 6 | 证书管理 |
| 7 | 配置 1 GiB swap |
| 0 | 退出 |

Swap 使用 `/swapfile.proxyall`，大小为 1 GiB，权限为 `600`，通过 `/etc/fstab` 开机挂载。需要至少 1152 MiB 可用磁盘空间及系统允许启用 swap；已有启用的 swap 时保持现有配置，同名文件不会被覆盖。fstab 备份保存在 `/etc/fstab.proxyall-backup.*`。

脚本更新保留现有配置，不升级 sing-box 核心。旧版无法更新时，可重新执行安装命令。更新前退出其他管理菜单；脚本备份位于 `/var/lib/proxyall/backup.*`。

## 日志与备份维护

安装、更新或打开管理入口时会启用自动维护，并安装所需的 `logrotate` 和 cron。每分钟检查 sing-box、Xray、Argo、中转操作、Nginx 和 HAProxy 的文件日志；每个日志超过 150 MiB 时轮转，清空当前文件并保留一份上次日志。两次检查之间，日志可能暂时超过阈值。

脚本更新、核心更新、Nginx/HAProxy 配置、DNS 配置及证书操作备份按来源各保留最近一份，不同站点的备份分别保留。维护任务会清理这些目录中的历史备份。证书归档文件保留在证书管理目录中。

systemd 240 及以上的 sing-box 和 Xray 服务将标准输出写入文件日志；现有运行中的服务需重启一次生效。已有 journal 记录继续由系统管理。实时日志菜单可同时查看 journal 和文件日志。

```bash
sb setup-maintenance    # 安装或修复自动维护任务
sb cleanup-logs         # 立即检查日志大小并清理历史备份
sb cleanup-backups      # 仅清理历史备份
```

## 使用说明

- **域名要分开**：例如 Emby 使用 `emby.example.com`，Reality 使用 `reality.example.com`，XHTTP 使用 `xhttp.example.com`。同一个完整域名无法按 SNI 分到两个后端。
- **默认共享 HTTPS 443**：HAProxy 只转发 TLS 流量。HTTP、自定义端口、IP 前端或非 systemd 环境使用直监听；已有 Nginx 独占 443 时需先迁移。
- **域名与端口**：自有域名需正确解析到服务器；使用 HTTP-01 申请或续期证书时，公网 TCP 80 必须可达，共享入口需放行 TCP 443。
- **Emby 网页默认关闭**：客户端 API 保留，可在反代菜单 **4** 中开启网页入口。
- **证书默认保留**：删除反代或节点不会顺带删除证书。证书管理会检查引用后归档清理，备份位于 `/var/lib/proxyall/certificates/`；其他自定义服务的引用需自行核对。
- **旧 DNS 配置兼容**：增删改节点时，在候选副本中适配主配置和中转配置的旧 DNS 格式，使用当前 sing-box 内核合并校验。校验与操作成功后统一提交；无法安全转换、校验失败或服务重启失败时恢复原配置。打开菜单和更新脚本本身保留现有节点配置。


## SS TCP 多路复用与裸 VLESS

在 `proxyall` 中选择 **2 → 1 → 8** 创建 SS 节点。服务端启用 TCP 多路复用，mihomo 节点 YAML 包含 `smux`：使用 `h2mux`，最大连接数为 4，新建连接前的最小流数为 4，仅复用 TCP。第 **4** 项同时启用 Padding，其他 SS 选项不启用 Padding。

创建和查看 SS 节点时显示 `ss://` 分享链接，包含地址、加密方式、密码、节点名称、UDP 开关及完整的 `smux` 参数；ShadowTLS 节点同时包含插件的主机名、密码和版本。聚合 Base64 订阅保留这些链接参数。mihomo 配置保存在 `/usr/local/etc/sing-box/clash.yaml`。

Sub-Store 的 SS 原生解析器不读取 `smux` 查询参数。在单条订阅中添加一次「脚本操作」，以本地代码使用 [substore-smux.js](substore-smux.js)，放在重命名等处理之前，导出选择 **Clash.Meta / mihomo**。该脚本从原始链接还原多路复用配置，支持直接粘贴链接和 Base64 订阅；解析与导出测试使用 Sub-Store **2.44.5**。

在添加节点菜单选择 **9 → VLESS（裸 TCP，无 TLS）** 创建普通 VLESS 节点。该节点使用 TCP 直监听，不启用 TLS、Reality 或 Vision；客户端 YAML 为 `tls: false`、`network: tcp`，分享链接为 `security=none`、`encryption=none`、`type=tcp`。批量创建也支持协议编号 **9**。

节点生成与回环通信测试使用临时目录和端口，不安装系统服务：

```bash
TEST_SINGBOX=/path/to/sing-box TEST_MIHOMO=/path/to/mihomo \
TEST_YQ=/path/to/yq python3 tests/tcp_nodes.py

TEST_SINGBOX=/path/to/sing-box TEST_YQ=/path/to/yq \
python3 tests/node_dns_compat.py
```

## VLESS + XHTTP + TLS（HTTP/2）

在 `proxyall` 中选择 **2 → 1 → 12** 添加 XHTTP 节点。按提示填写服务器地址、自有域名、端口、路径、节点名称和 XMUX 每条连接的最大并发数；默认端口为 443，并发数为 1，路径可自动生成。Xray 内核在添加时独立下载并校验官方 Release 的 SHA-256，也可通过节点管理主菜单 **18** 安装或更新。

- 客户端使用支持 XHTTP 的 mihomo，导出配置采用 `network: xhttp`、`mode: stream-up`、`alpn: [h2]`，启用证书验证。
- XMUX 并发数写入 mihomo YAML 的 `xhttp-opts.reuse-settings.max-concurrency` 和分享链接的 `extra.xmux.maxConcurrency`，连接可复用时间为 1800 秒；修改端口时保留并发数。
- 节点链接、mihomo YAML、查看、删除、修改端口及服务启停均由节点菜单管理。XHTTP 配置位于 `/usr/local/etc/sing-box/xray.json`；服务名为 `proxyall-xray`。
- 选择共享 443 时，流量经过 HAProxy → Nginx → 回环 Xray；Emby、Reality 和 XHTTP 使用不同完整域名。共享入口需要 systemd。
- 使用独立的 XHTTP 子域名。同域名的 Reality 节点删除后，可直接复用其有效证书；添加 XHTTP 时会检查并备份停用未被节点使用的受管 Reality 源站，保留证书、私钥及 HTTP-01 续期入口。其他已有 Nginx 站点仍会触发冲突检查；同机其他域名的网站或 Emby 可共用 HTTPS 端口。
- Nginx 使用 `/etc/nginx/certs/<域名>/cert` 与 `key`。可复用匹配域名且仍有效的证书，或通过 HTTP-01 申请并自动续期；申请时域名需直连解析到本机并开放 TCP 80。
- 使用 CDN 时，客户端服务器地址填写域名或 CDN 地址，SNI 与 Host 保持证书域名；CDN 需要支持 HTTP/2 和流式 gRPC，Cloudflare 需开启 gRPC。

测试需要本地二进制，不安装系统服务：

```bash
TEST_XRAY=/path/to/xray TEST_MIHOMO=/path/to/mihomo \
TEST_NGINX=/path/to/nginx TEST_YQ=/path/to/yq \
TEST_SINGBOX=/path/to/sing-box TEST_HAPROXY=/path/to/haproxy \
python3 tests/xhttp.py
```

测试使用临时目录和本机端口，结束时停止测试进程并清理文件。
