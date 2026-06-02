#!/bin/bash
set -e

echo "🚀 Instalando Genesis Admin Agent"

BASE=/opt/genesis-admin-agent
REPO_URL="github.com/sircagev/genesis-admin-agent.git"
SERVICE_NAME="admin-agent"

# ------------------------------------------------------------
# Recibir token GitHub como parámetro
# ------------------------------------------------------------
MODULES_GITHUB_TOKEN="${1:-}"

if [ -z "$MODULES_GITHUB_TOKEN" ]; then
    echo "⚠️ No se recibió token GitHub para módulos privados."
    echo "Ejemplo:"
    echo 'curl -sSL https://raw.githubusercontent.com/sircagev/genesis-admin-agent/main/install.sh | sudo bash -s -- "ghp_TU_TOKEN_REAL"'
fi

# ------------------------------------------------------------
# Clonar o actualizar repo público
# ------------------------------------------------------------
if [ -d "$BASE/.git" ]; then
    echo "📦 Repositorio existente, actualizando..."
    git -C "$BASE" pull
else
    echo "📦 Clonando repositorio privado..."
    git clone "https://${REPO_URL}" "$BASE"
fi

cd "$BASE"

# ------------------------------------------------------------
# Guardar token GitHub en .env privado para uso futuro
# ------------------------------------------------------------
if [ -n "$MODULES_GITHUB_TOKEN" ]; then
    echo "🔐 Guardando token GitHub para descarga futura de módulos..."

    cat > "$BASE/.env" <<EOF
GITHUB_TOKEN=${MODULES_GITHUB_TOKEN}
EOF

    chown root:root "$BASE/.env"
    chmod 600 "$BASE/.env"
else
    echo "⚠️ Se continúa sin GITHUB_TOKEN."
    echo "⚠️ create_instance.sh no podrá clonar modulosFE17 privados hasta configurar /opt/genesis-admin-agent/.env"
fi

# ------------------------------------------------------------
# Crear venv / instalar dependencias
# ------------------------------------------------------------
echo "🐍 Creando entorno virtual e instalando dependencias..."

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate

# ------------------------------------------------------------
# Crear config solo si no existe
# ------------------------------------------------------------
mkdir -p "$BASE/config"

if [ -f "$BASE/config/config.yaml" ]; then
    echo "🔐 Config existente detectada, se conserva token actual"
    TOKEN=$(grep '^token:' "$BASE/config/config.yaml" | sed 's/token:[[:space:]]*//' | tr -d '"')
else
    echo "🔐 Generando token del agente..."
    if [ ! -f "$BASE/config/config.yaml.tpl" ]; then
        echo "❌ ERROR: No existe $BASE/config/config.yaml.tpl"
        exit 1
    fi
    TOKEN=$(openssl rand -hex 32)
    sed "s/__AUTO_GENERATED__/${TOKEN}/" config/config.yaml.tpl > config/config.yaml
    chmod 600 config/config.yaml
fi

# ------------------------------------------------------------
# Asegurar scripts ejecutables
# ------------------------------------------------------------
if [ -d "$BASE/scripts" ]; then
    echo "⚙️ Dando permisos a scripts..."
    chmod +x "$BASE"/scripts/*.sh || true
fi

# ------------------------------------------------------------
# Instalar systemd
# ------------------------------------------------------------
echo "🧩 Instalando servicio systemd..."
if [ ! -f "$BASE/systemd/admin-agent.service.tpl" ]; then
    echo "❌ ERROR: No existe $BASE/systemd/admin-agent.service.tpl"
    exit 1
fi
sed "s|/opt/genesis-admin-agent|$BASE|g" systemd/admin-agent.service.tpl \
  > /etc/systemd/system/admin-agent.service

# ------------------------------------------------------------
# Hacer que systemd cargue el .env
# ------------------------------------------------------------
mkdir -p "/etc/systemd/system/${SERVICE_NAME}.service.d"

cat > "/etc/systemd/system/${SERVICE_NAME}.service.d/env.conf" <<EOF
[Service]
EnvironmentFile=-${BASE}/.env
EOF

# ------------------------------------------------------------
# Permitir que sudo conserve GITHUB_TOKEN
# ------------------------------------------------------------
echo "🔐 Configurando sudo para conservar GITHUB_TOKEN..."

cat > /etc/sudoers.d/genesis-admin-agent-env <<EOF
Defaults env_keep += "GITHUB_TOKEN"
EOF

chmod 440 /etc/sudoers.d/genesis-admin-agent-env
visudo -cf /etc/sudoers.d/genesis-admin-agent-env

# ------------------------------------------------------------
# Reiniciar servicio
# ------------------------------------------------------------
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

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

unset MODULES_GITHUB_TOKEN

echo "✅ Agente instalado correctamente"
echo "🔐 TOKEN DEL AGENTE (guárdalo en Admin Center):"
echo "----------------------------------------------"
echo "$TOKEN"
echo "----------------------------------------------"
