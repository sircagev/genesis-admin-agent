#!/bin/bash
set -e

echo "🚀 Instalando Genesis Admin Agent"

BASE=/opt/genesis-admin-agent
REPO_URL="github.com/sircagev/genesis-admin-agent.git"

# ------------------------------------------------------------
# Validar token
# ------------------------------------------------------------
# if [ -z "$GITHUB_TOKEN" ]; then
#   echo "❌ ERROR: Debes definir GITHUB_TOKEN"
#   echo "Ejemplo:"
#   echo "GITHUB_TOKEN=ghp_xxx bash install.sh"
#   exit 1
# fi

# ------------------------------------------------------------
# Clonar o actualizar repo
# ------------------------------------------------------------
if [ -d "$BASE/.git" ]; then
    echo "📦 Repositorio existente, actualizando..."
    git -C "$BASE" pull
else
    echo "📦 Clonando repositorio privado..."
    git clone "https://${GITHUB_TOKEN}@${REPO_URL}" "$BASE"
fi

cd "$BASE"

# ------------------------------------------------------------
# Crear venv / instalar dependencias
# ------------------------------------------------------------
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# ------------------------------------------------------------
# Crear config solo si no existe
# ------------------------------------------------------------
if [ -f "$BASE/config/config.yaml" ]; then
    echo "🔐 Config existente detectada, se conserva token actual"
    TOKEN=$(grep '^token:' "$BASE/config/config.yaml" | sed 's/token:[[:space:]]*//' | tr -d '"')
else
    echo "🔐 Generando token del agente..."
    TOKEN=$(openssl rand -hex 32)
    sed "s/__AUTO_GENERATED__/${TOKEN}/" config/config.yaml.tpl > config/config.yaml
    chmod 600 config/config.yaml
fi

# ------------------------------------------------------------
# Asegurar scripts ejecutables
# ------------------------------------------------------------
if [ -d "$BASE/scripts" ]; then
    chmod +x "$BASE"/scripts/*.sh || true
fi

# ------------------------------------------------------------
# Instalar systemd
# ------------------------------------------------------------
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

unset GITHUB_TOKEN

echo "✅ Agente instalado correctamente"
echo "🔐 TOKEN DEL AGENTE (guárdalo en Admin Center):"
echo "----------------------------------------------"
echo "$TOKEN"
echo "----------------------------------------------"
