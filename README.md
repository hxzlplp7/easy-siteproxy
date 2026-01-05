# Easy SiteProxy 一键部署

一键部署脚本，支持 **Linux** (Debian/Ubuntu/CentOS/Alpine) + **FreeBSD/Serv00/HostUno**。

## 快速开始

### 方式一：在线安装（推荐）

```bash
# 下载并运行安装脚本
curl -fsSL https://raw.githubusercontent.com/hxzlplp7/easy-siteproxy/main/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

### 方式二：本地安装

```bash
git clone https://github.com/hxzlplp7/easy-siteproxy.git
cd easy-siteproxy
chmod +x install.sh
./install.sh
```

## 功能特性

- **跨平台支持**
  - Linux: Debian/Ubuntu, CentOS/RHEL/Fedora, Alpine
  - FreeBSD: FreeBSD/Serv00/HostUno

- **自动安装 Node.js v22+**
  - 优先使用 NVM 安装
  - 自动检测并安装包管理器版本
  - 官方二进制兜底方案

- **服务管理**
  - systemd (Debian/Ubuntu/CentOS)
  - OpenRC (Alpine)
  - FreeBSD rc.d
  - Serv00/HostUno: nohup + cron 保活

- **交互式配置**
  - 代理域名 (proxy_url)
  - 访问密码 (token_prefix)
  - 监听端口 (local_listen_port)

- **反向代理模板**
  - Nginx 配置示例
  - Caddy 配置示例

## 菜单功能

```
╔═══════════════════════════════════════════════════╗
║        SiteProxy 一键部署管理脚本                  ║
╠═══════════════════════════════════════════════════╣
║  1. 安装 SiteProxy                                ║
║  2. 卸载 SiteProxy                                ║
║  3. 启动服务                                      ║
║  4. 停止服务                                      ║
║  5. 重启服务                                      ║
║  6. 查看状态                                      ║
║  7. 查看日志                                      ║
║  8. 修改配置                                      ║
╠═══════════════════════════════════════════════════╣
║  9. 反向代理模板 (Nginx/Caddy)                    ║
║  10. HTTPS 证书配置指南                           ║
║  11. 端口状态检测                                 ║
╠═══════════════════════════════════════════════════╣
║  0. 退出                                          ║
╚═══════════════════════════════════════════════════╝
```

## NAT VPS 特别说明

脚本能够在各类 NAT VPS 上正常安装和运行 SiteProxy 服务，但要实现 **对外可访问的 HTTPS 代理**，还需要配置反向代理和 SSL 证书：

### 场景分类

| 场景 | 推荐方案 | 菜单选项 |
|------|----------|----------|
| 有公网 IP + 80/443 可用 | certbot HTTP-01 | 选项 10 - 方案 A |
| NAT VPS 无 80 端口 | acme.sh DNS-01 | 选项 10 - 方案 B |
| 无公网入站（纯 NAT） | Cloudflare Tunnel | 选项 10 - 方案 C |

## 配置说明

安装完成后，配置文件位于 `~/siteproxy/config.json`：

```json
{
  "proxy_url": "https://your-proxy.domain.name",
  "token_prefix": "/your-password/",
  "local_listen_port": 5006,
  "description": "..."
}
```

| 配置项 | 说明 |
|--------|------|
| `proxy_url` | **必须**为 `https://` 开头的域名 |
| `token_prefix` | 访问密码，首尾斜杠必须保留；不设密码使用 `//` |
| `local_listen_port` | 本地监听端口，默认 5006 |

## 访问方式

安装配置完成后，通过以下格式访问：

```
https://your-proxy.domain.name/your-password/https://www.google.com
```

## 反向代理配置

### Nginx

```nginx
server {
    listen 80;
    server_name your-domain.com;

    location / {
        proxy_pass http://127.0.0.1:5006;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Caddy

```caddyfile
your-domain.com {
    reverse_proxy 127.0.0.1:5006
}
```

> 💡 **提示**: 使用 `certbot` 或 Caddy 自动获取 SSL 证书以启用 HTTPS。

## Serv00/HostUno 特别说明

脚本在 Serv00/HostUno 环境会自动：

1. 使用 `devil binexec on` 启用执行权限
2. 使用 `devil port add tcp <port>` 开放端口
3. 创建 `run.sh` 启动脚本和 `keepalive.sh` 保活脚本
4. 配置 cron 每分钟检测并自动拉起服务

如果自动配置失败，请登录控制面板手动配置端口。

## 目录结构

```
~/siteproxy/
├── bundle.cjs        # 主程序
├── config.json       # 配置文件
├── config.json.dist  # 配置模板
├── siteproxy.log     # 日志文件
├── siteproxy.pid     # PID 文件
├── run.sh            # 启动脚本 (Serv00)
└── keepalive.sh      # 保活脚本 (Serv00)
```

## 常见问题

### Q: Node.js 安装失败怎么办？

脚本会按以下顺序尝试安装：
1. NVM 安装
2. 系统包管理器 (apt/dnf/yum/apk/pkg)
3. 官方二进制下载

如果都失败，请手动安装 Node.js v22+：
```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
source ~/.bashrc
nvm install v22
```

### Q: 服务启动后无法访问？

1. 检查防火墙是否放行端口
2. 确认 `config.json` 中的 `proxy_url` 是否正确配置为 HTTPS
3. 确认反向代理配置是否正确指向 5006 端口

### Q: Serv00 上端口被占用？

使用 `devil port list` 查看已占用端口，修改 `config.json` 中的端口后重启服务。

## 致谢

- [SiteProxy](https://github.com/netptop/siteproxy) - 原始项目
- [NVM](https://github.com/nvm-sh/nvm) - Node Version Manager

## License

MIT
