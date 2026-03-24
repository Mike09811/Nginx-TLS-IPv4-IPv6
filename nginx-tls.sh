#!/bin/bash
set -e

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 root 用户执行此脚本！"
    exit 1
fi

# 检测包管理器
if command -v apt &>/dev/null; then
    PKG_MGR="apt"
elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
else
    echo "错误：未找到支持的包管理器（apt/yum/dnf）！"
    exit 1
fi

# 1. 安装依赖
echo "===== 安装 Nginx 和 Certbot ====="
if [ "$PKG_MGR" = "apt" ]; then
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y nginx certbot python3-certbot-nginx netfilter-persistent iptables-persistent
else
    $PKG_MGR install -y epel-release || true
    $PKG_MGR install -y nginx certbot python3-certbot-nginx iptables-services
fi

# 2. 交互获取配置信息（从 /dev/tty 读取，兼容 curl | bash）
read -p "请输入要配置的域名（如 example.com）: " DOMAIN < /dev/tty
read -p "请输入反向代理的源站地址（如 http://127.0.0.1:8080）: " TARGET < /dev/tty
read -p "是否开启 IPv6 支持？(y/n): " IPV6_ENABLE < /dev/tty
read -p "请输入申请 SSL 证书的邮箱: " EMAIL < /dev/tty

NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"

# 3. 先写一个仅 HTTP 的临时配置，用于 Certbot 验证
echo "===== 创建临时 Nginx 配置（用于证书申请）====="

IPV6_LISTEN_80=""
IPV6_LISTEN_443=""
if [ "$IPV6_ENABLE" = "y" ]; then
    IPV6_LISTEN_80="    listen [::]:80;"
    IPV6_LISTEN_443="    listen [::]:443 ssl;"
fi

cat > "$NGINX_CONF" << EOF
server {
    listen 80;
${IPV6_LISTEN_80}
    server_name ${DOMAIN};

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

# 重载 Nginx 使临时配置生效
systemctl reload nginx

# 4. 申请 SSL 证书
echo "===== 申请 Let's Encrypt SSL 证书 ====="
certbot certonly --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive

# 5. 写入完整的 HTTPS 配置
echo "===== 创建完整 Nginx 反向代理配置 ====="
cat > "$NGINX_CONF" << EOF
server {
    listen 80;
${IPV6_LISTEN_80}
    server_name ${DOMAIN};

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
${IPV6_LISTEN_443}
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;

    location / {
        proxy_pass ${TARGET};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 60s;
    }
}
EOF

# 6. 配置证书自动续期
echo "===== 配置证书自动续期 ====="
echo "0 0 1 * * root /usr/bin/certbot renew --quiet && systemctl reload nginx" >> /etc/crontab

# 7. 放行 80/443 端口
echo "===== 放行 80/443 端口 ====="
if command -v ufw &>/dev/null; then
    ufw allow 80/tcp
    ufw allow 443/tcp
fi

if [ "$IPV6_ENABLE" = "y" ]; then
    ip6tables -A INPUT -p tcp --dport 80 -j ACCEPT
    ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT
    ip6tables-save > /etc/iptables/rules.v6
fi

# 8. 重启 Nginx 并验证
echo "===== 重启 Nginx 服务 ====="
systemctl restart nginx
systemctl enable nginx
nginx -t && echo "===== 配置成功！=====" || echo "===== 配置出错，请检查日志！====="
