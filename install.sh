#!/bin/bash
set -e

echo "🚀 Instalando Genesis Admin Agent"

BASE=/opt/genesis-admin-agent

mkdir -p $BASE
cd $BASE

git clone https://github.com/sircagev/genesis-admin-agent.git .

python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

TOKEN=$(openssl rand -hex 32)

sed "s/__AUTO_GENERATED__/${TOKEN}/" config/config.yaml.tpl > config/config.yaml
chmod 600 config/config.yaml

sed "s|/opt/genesis-admin-agent|$BASE|g" systemd/admin-agent.service.tpl \
  > /etc/systemd/system/admin-agent.service

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable admin-agent
systemctl restart admin-agent

# ------------------------------------------------------------
# Configurar UFW (permitir puerto 8010/tcp)
# ------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
    echo "🔐 Configurando firewall (ufw)..."
    ufw allow 8010/tcp >/dev/null 2>&1 || true
    echo "📡 Reglas activas de UFW:"
    ufw status
else
    echo "⚠️ ufw no está instalado, se omite configuración de firewall"
fi

echo "✅ Agente instalado"
echo "🔐 TOKEN: $TOKEN"
