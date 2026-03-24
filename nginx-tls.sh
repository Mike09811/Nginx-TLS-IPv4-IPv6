#!/bin/bash
set -e

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 root 用户执行此脚本！"
    exit 1
fi

# 1. 安装依赖
echo "===== 安装 Nginx 和 Certbot ====="
apt update && apt install -y nginx certbot python3-certbot-nginx ip6tables-persistent || yum install -y nginx certbot python3-certbot-nginx ip6tables-services

# 2. 交互获取配置信息
read -p "请输入要配置的域名（如 example.com）: " DOMAIN
read -p "请输入反向代理的源站地址（如 http://127.0.0.1:8080）: " TARGET
read -p "是否开启 IPv6 支持？(y/n): " IPV6_ENABLE
read -p "请输入申请 SSL 证书的邮箱: " EMAIL

# 3. 创建 Nginx 配置文件
NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
echo "===== 创建 Nginx 反向代理配置 ====="
cat > $NGINX_CONF << EOF
server {
    listen 80;
    $( [ "$IPV6_ENABLE" = "y" ] && echo "listen [::]:80;" )
    server_name $DOMAIN;
    
    # 重定向 HTTP 到 HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    $( [ "$IPV6_ENABLE" = "y" ] && echo "listen [::]:443 ssl http2;" )
    server_name $DOMAIN;

    # SSL 证书配置
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;

    # 反向代理配置
    location / {
        proxy_pass $TARGET;
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

# 4. 申请 SSL 证书（国内服务器用阿里云镜像）
echo "===== 申请 Let's Encrypt SSL 证书 ====="
certbot certonly --nginx -d $DOMAIN --email $EMAIL --agree-tos --non-interactive --server https://acme.aliyun.com/v2/DV90 || \
certbot certonly --nginx -d $DOMAIN --email $EMAIL --agree-tos --non-interactive

# 5. 配置证书自动续期
echo "===== 配置证书自动续期 ====="
echo "0 0 1 * * /usr/bin/certbot renew --quiet && systemctl reload nginx" >> /etc/crontab

# 6. 重启 Nginx 并验证
echo "===== 重启 Nginx 服务 ====="
systemctl restart nginx && systemctl enable nginx
nginx -t && echo "===== 配置成功！=====" || echo "===== 配置出错，请检查日志！====="

# 7. 放行端口（IPv4/IPv6）
echo "===== 放行 80/443 端口 ====="
ufw allow 80/tcp && ufw allow 443/tcp || firewall-cmd --add-port=80/tcp --permanent && firewall-cmd --add-port=443/tcp --permanent
[ "$IPV6_ENABLE" = "y" ] && ip6tables -A INPUT -p tcp --dport 80 -j ACCEPT && ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT
