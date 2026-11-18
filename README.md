# ProxyAll

在 Linux VPS 上管理 Xray 节点和 Emby / Nginx 反代。所有新节点及中转共用一个 `proxyall-xray` 服务。可以只部署节点、只部署反代，或让两者共用公网 TCP 443。

## 安装与更新

以 root 运行，需要 Bash 和 curl。共享 443 需要 systemd。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/KevinChen222/ss_node/main/proxyall) --install
```

`proxyall` 菜单 1 管理反代，2 管理节点。创建第一个节点时下载并校验 Xray；已有核心可在节点菜单 9 更新。`sb` 是节点管理命令，`nginxproxy` 是反代管理命令。

```bash
proxyall --update        # 更新管理脚本
proxyall --certificates  # 查看引用、续期、验证或归档证书
proxyall --fix-http2     # 修复受管配置的 HTTP/2 旧语法
proxyall --swap          # 配置 1 GiB swap，保留已有启用的 swap
```

## 节点与客户端

| 节点菜单 | 服务端与客户端 |
| --- | --- |
| 1 / 11 | 单个 / 批量 VLESS TCP + Vision + Reality。Chrome 指纹、X25519MLKEM768 握手、XUDP；可选 X25519 或 ML-KEM-768 认证的 VLESS Encryption。默认 `encryption=none` 仍有 Reality 保护。 |
| 2 | VLESS XHTTP + Reality。Xray 处理握手，无需 Nginx 终止 TLS。 |
| 3 | VLESS XHTTP + TLS。Nginx 终止 HTTP/2，再转发至回环 Xray。 |
| 4 | 裸 VLESS TCP、Shadowsocks AES-128-GCM、带密码的 SOCKS5、VLESS / Trojan WS+TLS、VLESS gRPC+TLS。后三项复用 `/etc/nginx/certs/<域名>/cert` 与 `key`，由 Xray 终止 TLS。裸 TCP 和 SOCKS5 不提供传输加密。 |
| 5 / 6 / 7 | 查看链接和聚合 Base64 订阅 / 改公网端口 / 删除节点。 |
| 8 | 为一个入口绑定落地分享链接或 Xray outbound JSON 文件；输入 `direct` 解除绑定。其他入口继续走各自出站。 |

将生成的链接粘贴到 Sub-Store，输出选 `Clash.Meta / mihomo`。不要将服务器的 `xray.json` 当成客户端订阅。内部 `clash.yaml`、元数据及 `xray.json` 位于 `/usr/local/etc/sing-box/`；目录名保留以便原位更新。

Vision 的三种认证配置均按 Xray 26.11.9、Sub-Store 2.44.16、mihomo Alpha `2be2f08` 验证。`support-x25519mlkem768` 指 Reality 的混合密钥交换，独立于 VLESS 附加加密。这个 mihomo 构建没有 Reality `pqv` 验证密钥配置，生成器不启用依赖它的 ML-DSA-65 验证。Trojan 导出可省略 `tls: true`，mihomo 按 Trojan TLS 处理；仍需可信证书。

XHTTP 使用 `stream-up`、HTTP/2 和 XMUX。单连接最大并发可调，默认 1，可复用时长为 1800 秒。使用 CDN 时，仅选择支持 HTTP/2 和流式 gRPC 的 TLS 入口；Reality 使用直连。中转链接支持本菜单生成的传输组合；无法完整转换的第三方参数用 Xray outbound JSON 配置。

## 与 Emby 共用 443

| 同一个公网入口 | HAProxy 将连接交给 |
| --- | --- |
| `emby.example.com`、XHTTP TLS 域名 | 同一 Nginx 回环 HTTPS 入口（PROXY v2，保留来源地址） |
| WS+TLS、gRPC+TLS 的独立 SNI | 对应 Xray 回环监听 |
| 默认 Reality 后端 | Xray（原样透传 ClientHello，不添加 PROXY 头） |

每个共享入口有一个默认 Reality 后端；Vision 和 XHTTP Reality 若要同时运行，另一个使用独立端口。各后端使用不同完整域名。安装时已有其他程序独占 443，需要先释放或迁移它的监听。仅使用独立端口与远程 Reality 握手目标时，无需为节点启动 HAProxy 或 Nginx。

自有本机 Reality 源站、XHTTP HTTPS 和 Emby 使用同一套 Nginx、证书目录和 HTTP-01 webroot。申请证书时域名应直连本机，公网 TCP 80 可达。已有匹配且有效的证书可复用。删除站点或节点后，可在证书管理中查看剩余引用再归档。Emby 网页入口默认关闭，API 和播放仍开放；反代菜单 4 可调整。

## 从 sing-box 版本升级

更新脚本不会翻译旧节点、改写客户端订阅或停掉运行中的服务。已有受管 Xray XHTTP 节点继续由新菜单管理。旧 AnyTLS、TUIC 等节点需要换成新的 Xray 节点；原有 sing-box 链接不计入新的聚合订阅。

1. 保留旧订阅，在空闲端口创建 Xray 节点，先用自己的客户端确认流量。
2. 若旧服务由本脚本安装并由 systemd 管理，运行 `sb retire-sing-box` 停用其自启和监听。它将旧主配置、中转配置和路由快照归档到 `retired.*`，只摘除旧内核的 SNI 路由，保留 Emby、Xray、证书和续期任务。自建服务或 OpenRC 需要按原服务管理方式停用。
3. 需要时在节点菜单 6 将验证过的 Reality 节点改到共享 443，再更新订阅。历史配置文件和备份包含凭据，应保留在 root 专用目录。

## 维护与验证

受管日志每 15 分钟检查一次，超过 150 MiB 时轮转并保留一份；配置备份按来源保留。`sb setup-maintenance` 可修复维护任务，`sb cleanup-logs` 可立即检查。代理核心并不依赖管理菜单常驻。

以下测试在临时目录和回环端口运行。`TEST_SUBSTORE` 指向 Sub-Store Release 中的 `proxy-utils.esm.mjs`。

```bash
TEST_XRAY=/path/to/xray TEST_MIHOMO=/path/to/mihomo TEST_YQ=/path/to/yq \
TEST_NGINX=/path/to/nginx TEST_HAPROXY=/path/to/haproxy \
TEST_SUBSTORE=/path/to/proxy-utils.esm.mjs python3 tests/xhttp.py

TEST_XRAY=/path/to/xray TEST_MIHOMO=/path/to/mihomo \
TEST_SUBSTORE=/path/to/proxy-utils.esm.mjs python3 tests/xhttp_reality_traffic.py

python3 tests/xhttp_reality.py
python3 tests/installer.py
```
