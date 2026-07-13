#!/bin/bash

export UUID="a29738e5-bee1-c0fc-b484-ae7c49cbc828"
echo "🔑 核心 UUID 密码已强制锁定为固定值: $UUID"

echo "🔍 正在打捞当前容器的真实外网出口 IP 与归属地..."
REAL_IP=$(curl -s --max-time 3 ifconfig.me)
REAL_COUNTRY=$(curl -s --max-time 3 ipinfo.io/country)

if [ -z "$REAL_IP" ]; then REAL_IP="DynamicIP"; fi
if [ -z "$REAL_COUNTRY" ]; then REAL_COUNTRY="Cloud"; fi

NODE_REMARK="${REAL_COUNTRY}_${REAL_IP}"
echo "📍 探测成功！当前主机实际地理标记: $NODE_REMARK"

sed -i "s/UUID_PLACEHOLDER/$UUID/g" /app/config.json
sed -i "s/UUID_PLACEHOLDER/$UUID/g" /app/www/index.html
sed -i "s/NODE_REMARK_PLACEHOLDER/$NODE_REMARK/g" /app/www/index.html

httpd -p 8081 -h /app/www &
echo "🌐 静态网页服务已在内部 8081 端口挂载"

/usr/bin/xray -config /app/config.json &
echo "🚀 Xray 核心网关已在本地 8080 端口拉起"

echo "🚇 正在解析云端隧道环境变量..."

if [ -n "$TUNNEL_TOKEN" ]; then
  echo "👉 模式 [A] 激活：检测到 TUNNEL_TOKEN，正在建立官方固定隧道..."
  /usr/local/bin/cloudflared tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token "$TUNNEL_TOKEN" &

elif [ -n "$ARGO_AUTH" ] && [ -n "$ARGO_DOMAIN" ]; then
  if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
    echo "👉 模式 [B-1] 激活：检测到 JSON 证书凭证，正在本地流式重组隧道..."
    echo "$ARGO_AUTH" > /app/tunnel.json
    
    TUNNEL_ID=$(echo "$ARGO_AUTH" | grep -oE '"TunnelID":"[^"]+"' | cut -d'"' -f4)
    cat <<EOF > /app/tunnel.yml
tunnel: $TUNNEL_ID
credentials-file: /app/tunnel.json
protocol: http2
ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:8080
  - service: http_status:404
EOF
    /usr/local/bin/cloudflared tunnel --config /app/tunnel.yml run &
  else
    echo "👉 模式 [B-2] 激活：检测到 Token 形式的 ARGO_AUTH，正在向域名 $ARGO_DOMAIN 绑定大桥..."
    /usr/local/bin/cloudflared tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token "$ARGO_AUTH" &
  fi

else
  echo "👉 模式 [C] 激活：未检测到任何固定密钥，正在拉起 TryCloudflare 临时随机隧道..."
  /usr/local/bin/cloudflared tunnel --edge-ip-version auto --no-autoupdate --protocol http2 --url http://localhost:8080 &
fi

# ======================= 哪吒探针 =======================
NEZHA_SERVER="${NEZHA_SERVER:-}"
NEZHA_KEY="${NEZHA_KEY:-}"
NEZHA_TLS="${NEZHA_TLS:-true}"

if [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_KEY" ]; then
  echo "📡 正在启动哪吒探针..."

  ARCH="amd64"
  [ "$(uname -m)" = "aarch64" ] && ARCH="arm64"

  NEZHA_BIN="/app/nezha-agent"
  if [ ! -f "$NEZHA_BIN" ]; then
    echo "⬇️ 下载 nezha-agent (${ARCH})..."
    curl -sL -o /tmp/nezha.zip "https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_linux_${ARCH}.zip"
    unzip -o /tmp/nezha.zip -d /app/ && chmod +x "$NEZHA_BIN"
    rm -f /tmp/nezha.zip
  fi

  cat > /app/nezha-config.yml <<EOF
client_secret: ${NEZHA_KEY}
server: ${NEZHA_SERVER}
tls: ${NEZHA_TLS}
debug: false
disable_auto_update: true
disable_command_execute: true
report_delay: 3
EOF

  "$NEZHA_BIN" -c /app/nezha-config.yml &
  echo "✅ 哪吒探针已启动"
fi

while true; do
  sleep 15
  
  netstat -tln | grep -q :8080
  XRAY_GATE=$?
  pidof cloudflared > /dev/null
  CF_PROCESS=$?
  
  if [ $XRAY_GATE -ne 0 ] || [ $CF_PROCESS -ne 0 ]; then
    echo "🚨 【断流警报】检测到服务硬断流！(总入口:$XRAY_GATE, 隧道进程:$CF_PROCESS)"
    exit 1
  fi
done
