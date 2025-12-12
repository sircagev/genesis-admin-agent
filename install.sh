#!/bin/bash
set -e

echo "🚀 Instalando Genesis Admin Agent"

apt update
apt install -y python3 python3-venv git

BASE=/opt/genesis-admin-agent
CFG_DIR=/opt/genesispos

mkdir -p $BASE $CFG_DIR
cd $BASE

git clone https://github.com/GENESISPOS/genesis-admin-agent.git .

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

echo "✅ Agente instalado"
echo "🔐 TOKEN: $TOKEN"
