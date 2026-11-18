# ProxyAll

在 Linux VPS 上管理 Xray 节点和 Emby / Nginx 反代。所有新节点及中转共用一个 `proxyall-xray` 服务。可以只部署节点、只部署反代，或让两者共用公网 TCP 443。

## 安装与更新

以 root 运行，需要 Bash 和 curl。共享 443 需要 systemd。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/KevinChen222/ss_node/main/proxyall) --install
```

`proxyall` 菜单 1 管理反代，2 管理节点。创建第一个节点时下载并校验 Xray；节点菜单 1 进入添加节点子菜单，已有核心可在节点菜单 6 更新。`sb` 是节点管理命令，`nginxproxy` 是反代管理命令。

```bash
proxyall --update        # 更新管理脚本
proxyall --certificates  # 查看引用、续期、验证或归档证书
proxyall --fix-http2     # 修复受管配置的 HTTP/2 旧语法
proxyall --swap          # 配置 1 GiB swap，保留已有启用的 swap
```

## 节点与客户端

| 添加节点子菜单 | 服务端与客户端 |
| --- | --- |
| 1 | VLESS TCP + Vision + Reality。Chrome 指纹、X25519MLKEM768 握手、XUDP；支持 VLESS ENC。 |
| 2 | VLESS XHTTP + Reality，支持 VLESS ENC。Xray 处理握手，无需 Nginx 终止 TLS。 |
| 3 | VLESS XHTTP + TLS，支持 VLESS ENC。Nginx 终止 HTTP/2，再转发至回环 Xray。 |
| 4 / 5 / 6 | VLESS WS+TLS / Trojan WS+TLS / VLESS gRPC+TLS。复用 `/etc/nginx/certs/<域名>/cert` 与 `key`，由 Xray 终止 TLS。 |
| 7 / 8 / 9 | Shadowsocks AES-128-GCM / 裸 VLESS TCP / 带密码的 SOCKS5。裸 TCP 和 SOCKS5 不提供传输加密。 |

节点管理菜单 2 / 3 / 4 用于查看分享链接、改端口和删除节点，菜单 5 为选定入口绑定落地链接或 Xray outbound JSON，输入 `direct` 解除绑定。

节点列表输入 `0` 返回节点管理。删除确认选否、改端口输入 `0`、中转输入 `0` 或留空，会返回节点列表；填写添加参数时输入 `0` 取消本次添加并返回协议选择。取消不提交候选配置、不重启服务。核心更新需确认后执行。

将生成的链接粘贴到 Sub-Store，输出选 `Clash.Meta / mihomo`。不要将服务器的 `xray.json` 当成客户端订阅。内部 `clash.yaml`、元数据及 `xray.json` 位于 `/usr/local/etc/sing-box/`；目录名保留以便原位更新。

Vision + Reality、XHTTP + Reality 和 XHTTP + TLS 创建时均可选择 VLESS Encryption（ENC），默认启用 ML-KEM-768 认证，也可选择握手较小的 X25519 认证或不启用 ENC。两种 ENC 均使用 ML-KEM-768 + X25519 混合密钥交换，ML-KEM-768 认证额外提供后量子身份认证；代价是更长的分享链接和更多握手开销，不保证提高吞吐。XHTTP + TLS 的 ENC 独立于外层 TLS，可让 VLESS 内容在 TLS 终止后继续保持加密。旧节点不会自动更换密钥或开启 ENC；新配置的客户端必须导入完整链接。

上述三种节点的 ENC 选项已通过 Xray 26.11.9、Sub-Store 2.44.16、mihomo Alpha `2be2f08` 实际连接验证。服务端 `decryption` 与客户端 `encryption` 自动配对，改端口、查看链接和聚合订阅保留对应参数。

Vision + Reality 和 XHTTP + Reality 的分享链接始终包含 `support-x25519mlkem768=true`，Sub-Store 导出为 `reality-opts.support-x25519mlkem768: true`。它指 Reality 的混合密钥交换，独立于 VLESS ENC；XHTTP + TLS 不使用 Reality，不添加此字段。这个 mihomo 构建没有 Reality `pqv` 验证密钥配置，生成器不启用依赖它的 ML-DSA-65 验证。Trojan 导出可省略 `tls: true`，mihomo 按 Trojan TLS 处理；仍需可信证书。

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

对于本脚本安装的 systemd 服务，可运行 `sb migrate-sing-box`（节点菜单 8）。脚本先列出可迁移和跳过的入站。输入 `MIGRATE` 后会短暂停服，在原端口启动 Xray，验证服务后删除受管 sing-box 可执行文件和 systemd 服务。无可迁移节点时保留旧服务。

迁移器识别有匹配客户端记录的独立 VLESS、Trojan、SOCKS5 和普通 Shadowsocks 入站，保留端口、凭据和客户端名称。AnyTLS、TUIC、中转入口、共享路由、smux 等无法完整转换的配置会跳过；这些旧节点在切换后下线。菜单 2 可查看迁移后的分享链接。`retired.*` 目录保存旧核心、服务文件及配置，含私钥和密码，仅限 root 访问。

若需要先做客户端流量验证，可手动并行创建替代节点：

已有受管 Xray XHTTP 节点继续由新菜单管理。

1. 保留旧订阅，在空闲端口创建 Xray 节点，先用自己的客户端确认流量。
2. 若旧服务由本脚本安装并由 systemd 管理，运行 `sb retire-sing-box` 停用其自启和监听。它将旧主配置、中转配置和路由快照归档到 `retired.*`，只摘除旧内核的 SNI 路由，保留 Emby、Xray、证书和续期任务。自建服务或 OpenRC 需要按原服务管理方式停用。
3. 需要时在节点菜单 3 将验证过的 Reality 节点改到共享 443，再更新订阅。历史配置文件和备份包含凭据，应保留在 root 专用目录。

## 维护与验证

受管日志每 15 分钟检查一次，超过 150 MiB 时轮转并保留一份；配置备份按来源保留。`sb setup-maintenance` 可修复维护任务，`sb cleanup-logs` 可立即检查。代理核心并不依赖管理菜单常驻。

以下测试在临时目录和回环端口运行。`TEST_SUBSTORE` 指向 Sub-Store Release 中的 `proxy-utils.esm.mjs`。

```bash
TEST_XRAY=/path/to/xray TEST_MIHOMO=/path/to/mihomo TEST_YQ=/path/to/yq \
TEST_NGINX=/path/to/nginx TEST_HAPROXY=/path/to/haproxy \
TEST_SUBSTORE=/path/to/proxy-utils.esm.mjs python3 tests/xhttp.py

TEST_XRAY=/path/to/xray TEST_MIHOMO=/path/to/mihomo \
TEST_SUBSTORE=/path/to/proxy-utils.esm.mjs python3 tests/xhttp_reality_traffic.py

TEST_XRAY=/path/to/xray TEST_SUBSTORE=/path/to/proxy-utils.esm.mjs \
python3 tests/vless_encryption.py

python3 tests/xhttp_reality.py
python3 tests/installer.py
```
