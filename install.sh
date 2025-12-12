#!/bin/bash
set -e

echo "🚀 Instalando Genesis Admin Agent"

BASE=/opt/genesis-admin-agent
CFG_DIR=/opt/genesispos

mkdir -p $BASE $CFG_DIR
cd $BASE

git clone https://github.com/sircagev/genesis-admin-agent.git .

python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

TOKEN=$(openssl rand -hex 32)

sed "s/__AUTO_GENERATED__/${TOKEN}/" config/config.yaml.tpl > $CFG_DIR/config.yaml
chmod 600 $CFG_DIR/config.yaml

sed "s|/opt/genesis-admin-agent|$BASE|g" systemd/admin-agent.service.tpl \
  > /etc/systemd/system/admin-agent.service

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable admin-agent
systemctl restart admin-agent

# ------------------------------------------------------------
# Configurar UFW (permitir puerto 8019/tcp)
# ------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
    echo "🔐 Configurando firewall (ufw)..."

    # Asegurar SSH (para no bloquear acceso remoto)
    # ufw allow ssh >/dev/null 2>&1 || true

    # Permitir puerto del agente
    ufw allow 8010/tcp >/dev/null 2>&1 || true

    # Habilitar ufw solo si no está activo
    # if ufw status | grep -q "Status: inactive"; then
    #     ufw --force enable
    # fi

    echo "📡 Reglas activas de UFW:"
    ufw status
else
    echo "⚠️ ufw no está instalado, se omite configuración de firewall"
fi

echo "✅ Agente instalado"
echo "🔐 TOKEN: $TOKEN"
