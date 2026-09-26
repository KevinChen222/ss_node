# ProxyAll

基于他人开源脚本整理、修改的自用版本，把 sing-box 和 Emby / Nginx 反代放进一个菜单，方便日常管理。主要按自己的使用习惯做了调整，感谢原作者的工作。

## 功能

- **节点管理**：sing-box、Reality、SNI 自动选择、自有域名回落站点、中转及第三方节点导入。
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
| 0 | 退出 |

脚本更新保留现有配置，不升级 sing-box 核心。旧版无法更新时，可重新执行安装命令。更新前退出其他管理菜单；脚本备份位于 `/var/lib/proxyall/backup.*`。

## 使用说明

- **域名要分开**：例如 Emby 使用 `emby.example.com`，Reality 使用 `reality.example.com`。同一个完整域名无法按 SNI 分到两个后端。
- **默认共享 HTTPS 443**：HAProxy 只转发 TLS 流量。HTTP、自定义端口、IP 前端或非 systemd 环境使用直监听；已有 Nginx 独占 443 时需先迁移。
- **域名与端口**：自有域名需正确解析到服务器；使用 HTTP-01 申请或续期证书时，公网 TCP 80 必须可达，共享入口需放行 TCP 443。
- **Emby 网页默认关闭**：客户端 API 保留，可在反代菜单 **4** 中开启网页入口。
- **证书默认保留**：删除反代或节点不会顺带删除证书。证书管理会检查引用后归档清理，备份位于 `/var/lib/proxyall/certificates/`；其他自定义服务的引用需自行核对。

测试记录见 [REGRESSION.md](REGRESSION.md)，已知边界见 [AUDIT.md](AUDIT.md)。本地隔离测试不能代替真实 VPS 上的安装、续期和连接验证。
