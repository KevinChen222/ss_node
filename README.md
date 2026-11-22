```bash
bash <(curl -fsSL https://raw.githubusercontent.com/KevinChen222/ss_node/main/proxyall) --install
```

已安装的服务器运行 `proxyall --update`。从 `2.0.8` 升级时，第一次更新会替换三个入口脚本。进入新版菜单后，再选择一次更新，安装 `common.sh` 和 `sni_router.sh`。之后每次更新都会一起校验和安装这五个文件。
