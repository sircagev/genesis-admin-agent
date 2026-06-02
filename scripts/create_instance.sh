#!/bin/bash
set -e
trap 'echo "Error detectado. Revirtiendo cambios..."; rollback' ERR

if [ -z "$1" ]; then
    echo "Uso: $0 NOMBRE_CARPETA"
    exit 1
fi

if [ -z "$2" ]; then
    echo "Uso: $0 NOMBRE_CARPETA MAIN_PORT"
    exit 1
fi

BASE_DIR="/opt/$1"
REPO_ODDO="https://github.com/odoo/odoo.git"

if [ -z "$GITHUB_TOKEN" ]; then
    echo "ERROR: GITHUB_TOKEN no definido"
    exit 1
fi

REPO_MODULOS="https://github.com/evopos30/modulosFE17.git"

CREADOS=()

rollback() {
    echo "Revirtiendo cambios..."
    for item in "${CREADOS[@]}"; do
        if [ -e "$item" ]; then
            rm -rf "$item"
            echo "Eliminado: $item"
        fi
    done
    echo "Rollback completado."
}

# Crear usuario de PostgresSQL con el mismo nombre de la empresa
echo "Creando usuario PostgresSQL: $1"
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$1'" | grep -q 1 || \
sudo -u postgres psql -c "CREATE ROLE $1 WITH LOGIN SUPERUSER CREATEDB CREATEROLE PASSWORD 'odoo';"

# Hacer backup del pg_hba.conf
PG_HBA="/etc/postgresql/16/main/pg_hba.conf"
echo "Haciendo backup de $PG_HBA"
sudo cp "$PG_HBA" "${PG_HBA}.bak"
CREADOS+=("${PG_HBA}.bak")

# Añadir la línea al final del archivo
echo "Añadiendo configuración para el usuario $1 en $PG_HBA"
PG_LINE="host    all       $1    127.0.0.1/32    scram-sha-256"

if ! grep -qF "$PG_LINE" "$PG_HBA"; then
    echo "$PG_LINE" | sudo tee -a "$PG_HBA" > /dev/null
    sudo systemctl reload postgresql
fi

echo "Creando carpeta base: $BASE_DIR"
mkdir -p "$BASE_DIR"
CREADOS+=("$BASE_DIR")

cd "$BASE_DIR"

echo "Clonando Odoo desde $REPO_ODDO"
git clone "$REPO_ODDO" --depth 1 --branch 17.0 --single-branch odoo-server
CREADOS+=("$BASE_DIR/odoo-server")

cd odoo-server
echo "Eliminando .git y .github"
rm -rf .git
rm -rf .github

echo "Clonando módulos personalizados desde $REPO_MODULOS"
git -c http.extraHeader="Authorization: Bearer ${GITHUB_TOKEN}" \
    clone "$REPO_MODULOS"
CREADOS+=("$BASE_DIR/odoo-server/modulosFE17")

sudo chown -R odoo:odoo "/opt/$1/odoo-server"

# Crear el entorno virtual
echo "Creando entorno virtual en $BASE_DIR/odoo-server/venv"
python3 -m venv "${1}venv"
CREADOS+=("$BASE_DIR/odoo-server/${1}venv")

source "$BASE_DIR/odoo-server/${1}venv/bin/activate"
pip3 install wheel
pip3 install -r requirements.txt  # si existe
pip3 install -r modulosFE17/requirements17.txt  # si existe
deactivate

# ------------------ SECCIÓN CAMBIADA / AÑADIDA ------------------
# Crear archivo de configuración de Odoo automáticamente
ODOO_CONF="/etc/odoo${1}.conf"
ODOO_USER="$1"
ADMIN_PASSWD="genesispos"      # Cambiar por tu contraseña segura
DB_PASSWD="odoo"         # Cambiar por la contraseña del usuario PostgreSQL
ADDONS_PATH="$BASE_DIR/odoo-server/addons,$BASE_DIR/odoo-server/modulosFE17/custom-addons,$BASE_DIR/odoo-server/modulosFE17/modulos"
LOG_FILE="/var/log/odoo/odoo-server-${1}.log"

echo "Creando archivo de configuración: $ODOO_CONF"
sudo tee $ODOO_CONF > /dev/null <<EOF
[options]
; Contraseña maestra para operaciones de base de datos
admin_passwd = $ADMIN_PASSWD

; Datos de la base de datos PostgreSQL
db_host = 127.0.0.1
db_port = 5432
db_user = $ODOO_USER
db_password = $DB_PASSWD

; Rutas de módulos
addons_path = $ADDONS_PATH

; Configuración del servidor Odoo
xmlrpc_port = $2
longpolling_port = $(( $2 + 1 ))
xmlrpc_interface = 127.0.0.1
proxy_mode = True

workers = 2
max_cron_threads = 1

limit_time_cpu = 360
limit_time_real = 720

; Registro de logs
logfile = $LOG_FILE
log_level = info
EOF

# Ajustar permisos
sudo chown odoo:odoo $ODOO_CONF
sudo chmod 640 $ODOO_CONF

echo "Archivo de configuración creado"
# ------------------ FIN SECCIÓN CAMBIADA / AÑADIDA ------------------

# Crear el servicio
SYSTEM_PATH="/lib/systemd/system/odoo-server-${1}.service"
sudo tee $SYSTEM_PATH > /dev/null <<EOF
[Unit]
Description=Odoo Server for ${1}
After=postgresql.service

[Service]
User=odoo
Group=odoo
ExecStart=/opt/${1}/odoo-server/${1}venv/bin/python /opt/${1}/odoo-server/odoo-bin -c /etc/odoo${1}.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl start odoo-server-${1}.service
sudo systemctl enable odoo-server-${1}.service
sudo systemctl status odoo-server-${1}.service --no-pager

# ------------------ SECCIÓN NGINX ------------------
NGINX_CONF="/etc/nginx/sites-available/${1}.conf"
DOMAIN="${3:-${1}.genesispos.com.co}"
ODOO_PORT="$2"
ODOO_LONGPOLL_PORT=$((ODOO_PORT + 1))

echo "Creando archivo Nginx: $NGINX_CONF"
sudo tee $NGINX_CONF > /dev/null <<EOF
# ===========================
# UPSTREAMS (Odoo backend)
# ===========================
upstream odoo${1} {
    server 127.0.0.1:${ODOO_PORT};
}
upstream odoochat${1} {
    server 127.0.0.1:${ODOO_LONGPOLL_PORT};
}

# ===========================
# WEBSOCKET UPGRADE MAP
# ===========================
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# ===========================
# REDIRECCIÓN HTTP → HTTPS
# ===========================
#server {
#    listen 80;
#    server_name ${DOMAIN};
#    return 301 https://\$host\$request_uri;
#}

# Servidor HTTPS
server {
    #listen 443 ssl http2;
    listen 80;
    server_name ${DOMAIN};

    # Logs
    access_log /var/log/nginx/odoo-${1}.access.log;
    error_log /var/log/nginx/odoo-${1}.error.log;

    # Body Size
    client_max_body_size 100M;

    # Timeouts
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Headers
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;

    # WebSocket
    location /websocket {
        proxy_pass http://odoochat${1};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Longpolling
    location /longpolling {
        proxy_pass http://odoochat${1};
    }

    # Ruta principal Odoo
    location / {
        proxy_redirect off;
        proxy_pass http://odoo${1};
    }

    # Gzip
    gzip on;
    gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
}
EOF

# Habilitar el sitio y recargar Nginx
sudo ln -s /etc/nginx/sites-available/${1}.conf /etc/nginx/sites-enabled/ 2>/dev/null || true
sudo nginx -t
sudo certbot --nginx -d ${DOMAIN} --no-redirect
# Descomentar;
sudo sed -i '/#server {/,/#}/ s/^#//' /etc/nginx/sites-available/${1}.conf
sudo sed -i 's/^#listen 443 ssl http2;/listen 443 ssl http2;/' /etc/nginx/sites-available/${1}.conf
sudo sed -i 's/^listen 80;/#listen 80;/' /etc/nginx/sites-available/${1}.conf

sudo systemctl reload nginx

echo "Archivo Nginx creado y recargado correctamente."
# ------------------ FIN SECCIÓN NGINX ------------------


echo "Script completado correctamente."