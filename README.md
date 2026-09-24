这个脚本是copy别人的  自己稍微改了改方便用



# ProxyAll

ProxyAll 统一管理 sing-box 节点与 Emby / Nginx 反向代理。代理服务端仅使用 sing-box，保留 Reality、SNI 自动选择、自有域名 Origin、HAProxy 443 共享，以及中转和第三方出站导入。

```text
proxyall
├── sing-box 管理
│   ├── sb.sh
│   ├── advanced_relay.sh
│   └── parser.sh
└── Emby / Nginx 反代
    └── deploy.sh
```

公网 TCP 443 由 HAProxy 监听，只读取 ClientHello SNI，不终止 TLS。Reality 默认转发至 `127.0.0.1:2443`，Emby HTTPS 转发至 Nginx `127.0.0.1:8444`；两个域名必须不同。Nginx 后端使用 PROXY protocol。自有 Reality HTTPS Origin 使用独立的 `127.0.0.1:8443`。

`deploy.sh` 优先通过 `/usr/local/bin/sb sni-router ...` 管理共享路由；内置兜底仅用于必要的恢复保护。`tls_routes` 仍服务于 sing-box AnyTLS，不能清空。

## 安装与更新

发布时将五个主脚本配套上传到 `KevinChen222/ss_node` 的 `main` 分支，并保持 LF 换行。发布前运行 `python tests/check_release.py` 检查嵌套 SHA256 和语法。

以下命令以 root 在 Linux VPS 上执行。首次下载需要 Bash、curl 和可用的 CA 证书；Debian/Ubuntu 缺少这些依赖时先运行：

```bash
apt-get update && apt-get install -y bash curl ca-certificates
```

新 VPS 安装管理脚本（内核安装在 sing-box 菜单中另行选择）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/KevinChen222/ss_node/main/proxyall) --install
```



安装器只替换五个管理脚本，不升级内核、不重启业务、不迁移监听端口。旧脚本备份位于 `/var/lib/proxyall/backup.*`，安装失败会回滚；这不是完整业务配置备份。遇到无法识别的现有目标文件会在写入前停止，不应先删除原文件。


菜单：**1** Emby 反代；**2** sing-box；**3** 检查脚本更新；**4** 只卸载统一入口；**0** 退出。




