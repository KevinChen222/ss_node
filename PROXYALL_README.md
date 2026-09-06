# proxyall 使用与检查说明

## 上传清单

必须将以下 **五个文件配套上传到 `KevinChen222/ss_node` 的 `main` 分支根目录**，建议一次提交：

| 文件 | 用途 |
| --- | --- |
| `proxyall` | 新增的统一入口，无 `.sh` 后缀 |
| `sb.sh` | 修复后的 sing-box 主脚本与 SNI 路由管理器 |
| `advanced_relay.sh` | 修复后的中转脚本 |
| `parser.sh` | 修复后的节点解析器 |
| `deploy.sh` | 修复后的 Emby 反代脚本 |

推荐同时上传 `.gitattributes`、本说明和 `tests/`。不要上传 `.proxyall-test/`，该目录只是本地检查工具、原文件备份和调试文件。

五个脚本通过固定 SHA-256 相互校验。首次必须上传配套文件；以后只修改 `proxyall` 本身、四个组件内容和哈希均未变化时，可以单独更新入口。修改任何组件后必须一起更新引用它的哈希。

以后修改脚本后，先执行 `python tests/update_proxyall_hashes.py`，再运行回归检查并提交整套文件。保持 UTF-8、LF 换行，无 BOM；`.gitattributes` 用来防止 Git 在 Windows 上改成 CRLF。

## 首次安装

先完成上述上传，再在 Linux VPS 的 **root 终端**执行以下整个命令块。需要已有 Bash 和 curl；缺少 curl 时先用系统包管理器安装 `curl ca-certificates`。

```bash
bash -c '
  proxyall_tmp=$(mktemp) || exit 1
  trap "rm -f -- \"\$proxyall_tmp\"" EXIT
  curl --proto "=https" --tlsv1.2 -fLsS --connect-timeout 10 --max-time 120 \
    https://raw.githubusercontent.com/KevinChen222/ss_node/main/proxyall \
    -o "$proxyall_tmp" || exit 1
  bash -n "$proxyall_tmp" || exit 1
  bash "$proxyall_tmp" --install
' || printf '\nproxyall 安装未完成，请查看上方错误；当前终端可继续使用。\n'
```

完成后进入菜单。以后直接输入：

```bash
proxyall
```

普通用户先运行 `sudo -i`，然后执行安装命令。不要用 `sh proxyall`，也不要将脚本通过管道传入 Bash；菜单需要正常的终端输入。

命令在独立 Bash 中下载和安装，临时文件的退出清理也只作用于子进程。末尾的 `|| printf ...` 可避免安装失败触发外层登录 Shell 的 `set -e`；请完整复制，不要单独在 SSH 登录 Shell 中执行 `set -e`。请在正常交互终端粘贴，不要设成 SSH 客户端的会话启动／远程命令（该模式下命令结束会关闭会话）。

共享 443 沿用原脚本的 systemd 要求，推荐在 Debian / Ubuntu 的 systemd VPS 使用。非 systemd 系统可查看／管理原有非共享配置，但不能部署本套 HAProxy 共享入口。

## 菜单与目录

菜单包含 Emby 反代、sing-box 配置、检查脚本更新、卸载脚本、退出；选项间保留空行。中转和解析功能仍从 sing-box 菜单的进阶功能进入，不另建第二套配置。

| VPS 路径 | 行为 |
| --- | --- |
| `/usr/local/bin/proxyall` | 新增统一快捷入口 |
| `/usr/local/bin/sb` | 沿用主脚本快捷入口 |
| `/usr/local/bin/nginxproxy` | 沿用反代快捷入口 |
| `/usr/local/etc/sing-box/advanced_relay.sh` | 沿用组件位置 |
| `/usr/local/etc/sing-box/parser.sh` | 沿用组件位置 |
| `/usr/local/etc/sing-box/` | 原节点、订阅、中转、元数据和密钥目录，保持原位置 |
| `/etc/nginx/conf.d/`、`/etc/nginx/certs/` | 原站点和证书目录，保持原位置 |
| `/var/lib/sb-sni-router/state.json` | 沿用唯一 SNI 路由状态文件 |
| `/etc/haproxy/haproxy.cfg` | 仍由原 SNI 路由管理器维护 |
| `/var/lib/proxyall/` | 仅保存统一入口的下载暂存、提交记录、会话锁和旧脚本备份 |

第一次安装与检查更新均只替换脚本，不重写上述业务配置、不启动或重启服务、不升级 sing-box 核心。备份为 `backup.*` 目录，权限只允许 root 访问；不会自动清理旧备份。

已有且带原脚本管理标记的 `sb` / `nginxproxy` 可以原位置更新。旧中转与解析组件通过管理标记、已知哈希或 Bash 语法加固定目录和多项函数特征识别；识别时不会执行旧组件，通过检查后先备份再替换。无法识别的文件或符号链接仍会被保留，操作中止并显示具体路径，请勿为绕过检查而删除旧目录。

**1.0.1 历史修复：** 1.0.0 只认可本次提供的两份旧组件的精确哈希，会误拒绝 VPS 上其他历史版本。该检查发生在替换任何脚本之前，不会更改业务配置。仅从 1.0.0 更新到 1.0.1 时可以只替换入口；本次 1.1.0 还修改了核心升级逻辑，必须配套更新 sb.sh 与 proxyall。

进入子菜单后，用户明确选择的添加、修改、删除、安装核心等操作仍会执行相应业务变更。请勿在其他终端同时用独立的 `sb` / `nginxproxy` 修改配置；统一入口的会话锁只互斥其他 `proxyall` 会话。

## 共用 443

```text
公网 TCP 443 → HAProxy
  Emby 域名 SNI → 127.0.0.1:8444 → Nginx（接收 PROXY v2）
  额外 TLS SNI → 对应 sing-box 回环端口（不发送 PROXY 协议）
  默认后端     → 127.0.0.1:2443 等 → Reality（不发送 PROXY 协议）
```

- 从 `proxyall` 新建 Emby 默认使用 HAProxy，前端必须是域名、HTTPS 和公网 443。
- 新建 VLESS Reality，包括中转入口，默认公网端口 443；HAProxy 提示默认为启用。仍可明确选择其他端口或直监听。
- Emby 域名和 Reality SNI 必须不同。现有实现只支持一个默认 Reality 后端；已有节点可在进阶中转中复用，不应再次创建同一个公网入口。
- 仅安装／更新入口，不会迁移已经运行的直监听配置，也不会改客户端地址或凭据。
- Emby 添加共享入口时，原 `sb sni-router prepare` 可迁移主配置中直接监听 443 的单个 Reality 节点；客户端仍使用 443。这是明确部署时的原有功能。
- 如果老 Emby、其他 Nginx 站点或第三方服务仍直接占用 TCP 443，不能同时让 HAProxy 绑定它。需先迁移这些站点的监听；本入口不会擅自停掉不明服务或覆盖第三方 HAProxy 配置。原来已经启用 SNI 共享的 VPS 无需迁移。
- HAProxy 不处理 UDP；Hysteria2 / TUIC 的 UDP 443 与 TCP 443 是不同资源。

## 更新与卸载

“检查脚本更新”先解析 `main` 的一个 Git 提交，所有文件都从该提交下载。通过 Bash 语法、固定哈希及组件互相引用的哈希校验后，显示变化并询问是否更新。旧脚本全部备份后才开始替换；下载失败或安装中途失败会保留／恢复旧脚本。

从统一入口进入子脚本后，子脚本的自更新选项会提示回统一菜单更新，避免不同版本混用。单独执行 `sb` 或 `nginxproxy` 时，仍保留它们自己的更新方式；`deploy.sh` 的更新地址现已统一为 `ss_node` 仓库。

**卸载默认只删除 `proxyall` 入口**，输入 `UNINSTALL` 才执行。它保留原管理脚本、备份、定时任务、sing-box、Nginx、HAProxy 和所有配置。之后仍可用 `sb` / `nginxproxy` 管理服务。需要删除节点或反代链路时，进入对应管理脚本操作。

## 本次修复与 sing-box 1.14

### 1.1.0：每次核心更新自动适配配置

本版需同时更新仓库中的 **sb.sh 和 proxyall**（入口保存了 sb.sh 的新哈希），其余三个组件内容保持上一版。VPS 上先在统一菜单选择“检查脚本更新”，完成后进入“sing-box 配置 → [15] 安装/更新 Sing-box 核心”。

每次执行核心更新，包括同版本重装，都会下载候选核心、读取其版本，对原位置的 `config.json` 和 `relay.json` 制作临时副本并联合转换，再让候选核心检查两份合并配置。不会用“一次迁移完成”的标记跳过检查；检查时也不会依赖 `ENABLE_DEPRECATED_*` 环境变量绕过旧字段限制。

自动适配包含：

- 旧 DNS 多服务器格式：local、UDP、TCP、TLS、HTTPS、QUIC、HTTP3、DHCP、FakeIP，以及规则引用的 RCode 响应；保留已有标签、地址、端口、路径、解析器、detour、规则与相关设置。
- 纯 outbound DNS 规则与旧出站 domain_strategy 转换成域名解析器配置；新旧字段冲突不会强行覆盖。
- 旧 block / dns 出站转换成规则动作，跨主配置与中转配置的引用一起处理；旧 direct 出站的目标地址覆盖转换到路由规则。
- 旧入站 sniff、解析策略、UDP 域名映射选项转换成按入站匹配的规则；无标签时生成不冲突的标签；合并 TUN 地址字段，清理已失效的旧 ECH 选项。
- 目标版本为 1.14 或更新版本时，HY2 出站缺少 `disable_chrome_parrot` 会补为 `true`，保留旧握手方式以兼容 Ed25519 对端。用户明确设置的 `false` 会保留。

只有全部副本通过目标核心检查，才应用配置、替换核心并重启 sing-box。预检查失败不会重启旧服务；应用后失败或收到可捕获的退出信号时，尝试恢复旧核心、配置与服务文件。新旧核心均通过同目录临时文件再替换，避免跨文件系统覆盖运行中的二进制。升级锁在返回菜单后释放。

每次升级前的备份保存在 `/root/.singbox-update.*`，成功后也保留，并显示具体目录。主配置、中转配置、订阅文件、旧核心和原服务文件包含在备份中；Nginx、HAProxy、证书与节点凭据不因该迁移而重建。

自动修改依据已知格式的迁移规则，不会猜测未来版本的新字段，也不会删除不认识的配置来凑出可启动文件。例如带动态匹配条件的 outbound DNS 规则、selector/detour 指向旧特殊出站、启用旧 sniff_override_destination 或未知字段，若没有等价转换方式，会说明原因并取消本次升级。升级后仍需实际测试各条代理链路；配置通过检查与服务重启成功不等于所有远端都可连接。转换依据：[官方迁移说明](https://sing-box.sagernet.org/migration/)。

本次查阅官方发布信息，最新稳定版为 **1.14.0**。没有让统一入口自动升级核心；核心升级仍由 sing-box 菜单明确触发。[官方版本记录](https://sing-box.sagernet.org/changelog/#1140)

已修复或补强：

1. **落地 Token 错误地址**：HAProxy 前置的节点原来会导出 `127.0.0.1` 和内部端口，现在导出公网地址与 443。AnyTLS Reality Token 同时保留公钥、Short ID 和 uTLS；传输配置保留 gRPC 与 WebSocket early-data。
2. **Vision 误拦截**：移除跨协议中转一律禁止 VLESS Vision 的限制，保留并交给 sing-box VLESS 出站处理 `flow`；未知 flow 会被拒绝。
3. **节点解析丢失信息**：补充 gRPC 与 WS early-data，拒绝不支持的传输类型和 SS 插件，校验基本输出及端口范围。无效链接返回明确错误，不把未知传输静默当作 TCP。
4. **TLS 校验被无条件关闭**：HY2 / TUIC / AnyTLS 等导入改为遵循链接的 `insecure` / `allowInsecure` / `skip-cert-verify`，默认校验证书。自签名节点的分享链接需要明确带跳过校验参数。
5. **打开菜单自动改业务**：移除 `sb` 进入菜单时自动删除旧中转、强制改默认出口、迁移 DNS 和改写旧服务文件的行为。服务迁移留到用户执行核心更新时处理。
6. **核心升级适配**：每次在副本中联合迁移主配置与中转配置，检查通过后应用；迁移和回滚范围见上文。DNS 菜单的单独设置流程仍保留原有保守检查。
7. **SNI 锁与状态保护**：路由变更在子 shell 内持锁，函数返回后释放；等待锁设置超时。损坏／空状态文件不被当作全新配置清空。缺失 `sb` 时，Emby 独立兜底逻辑遇到它不认识的额外 TLS SNI 路由会拒绝改写。
8. **UDP 入口检查**：中转 HY2 / TUIC 按 UDP 检查端口占用，避免把 TCP 与 UDP 当成同一个端口资源；补充入口端口范围检查。

1.14 已删除旧 DNS server 格式；`tls.acme` 改为弃用、计划在 1.16 删除。当前脚本用独立的 acme.sh 管证书，不依赖 sing-box 内联 ACME，无须因此重做证书目录。[官方弃用表](https://sing-box.sagernet.org/deprecated/)、[迁移说明](https://sing-box.sagernet.org/migration/)

1.14 的 HY2 出站默认模仿 Chrome QUIC 握手，对 Ed25519 服务端证书有兼容限制。本版升级会补齐缺失的禁用模拟选项；Token／链接导入仍保留相应提示。新生成的本套 HY2 证书使用 ECDSA；明确选择保留模拟的出站不会被强行修改。[官方变更说明](https://sing-box.sagernet.org/changelog/#1140-beta7)

## 验证情况与范围

本地使用官方发布且校验了 SHA-256 的 sing-box 1.14.0 和 ShellCheck 0.11.0 检查：

- 五个脚本通过 Bash 语法及 ShellCheck error 级检查。旧脚本尚有变量声明／引用方式等 warning，不代表完全消除所有静态警告。
- 11 组协议／传输的解析结果通过真实 `sing-box check`，包含 VLESS Reality、gRPC、WS early-data、Trojan、HY2、TUIC、AnyTLS、SS、SOCKS 和 VMess。
- DNS 构建、旧标签／规则保留、拒绝破坏自定义 DNS 的迁移；VLESS / AnyTLS Reality Token 解码后地址正确。
- HAProxy 配置输出检查了 SNI、后端端口和 PROXY v2 边界。
- 在临时目录验证整套文件哈希、安装、注入失败后的回滚、未知文件保护、业务文件不变、菜单与卸载、固定 Git 提交下载和网络失败清理。
- 1.0.1 补充旧组件不同哈希的原位置升级与备份测试；直接执行本文安装命令，模拟下载失败、语法失败、安装失败和菜单输入，验证外层启用 `set -e -u`（含导出选项）后仍继续运行，且不改外层 trap 和选项。
- 实际启动两个测试 sing-box 进程，通过本机 SOCKS → VLESS Vision → HTTP 完成请求，验证 Vision 跨协议中转。
- 自动适配测试直接使用 1.14 核心，验证旧配置先失败、转换后通过，以及成功升级、同版本再次修复、预检失败不重启、启动失败回滚、中断回滚、备份保留。转换后的 sniff / direct 目标覆盖规则还通过真实本机 SOCKS → HTTP 请求验证。测试中系统包安装、下载、服务控制与 flock 原语用替身隔离，没有操作真实 VPS。

测试在 Windows 的 Git Bash 与官方 Windows sing-box 下完成；没有连接或操作你的 VPS，未做真实 Linux systemd / HAProxy / Nginx 启停和公网证书签发测试。VPS 上实际部署仍由原脚本执行 `sing-box check`、`haproxy -c`、`nginx -t` 和 HTTPS 端到端检查。文件备份不等于业务数据备份，建议首次升级核心前保留 VPS 快照。

Linux 上复验（需要 Bash、jq、openssl、Python 3、sing-box 1.14）：

```bash
python3 tests/test_proxyall.py
python3 tests/test_proxyall_install.py
python3 tests/test_core_upgrade.py
python3 tests/test_vision.py
shellcheck -S error proxyall sb.sh advanced_relay.sh parser.sh deploy.sh
```
