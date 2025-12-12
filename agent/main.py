import subprocess
from typing import List, Optional

import yaml
from fastapi import FastAPI, Header, HTTPException, Query, Depends
from pydantic import BaseModel

CONFIG_PATH = "/opt/genesis-admin-agent/config/config.yaml"

with open(CONFIG_PATH, "r") as f:
    CONFIG = yaml.safe_load(f)

ADMIN_TOKEN = CONFIG.get("token")

ALLOWED_EXACT = CONFIG.get("allowed_exact", [])
ALLOWED_PREFIX = CONFIG.get("allowed_prefix", [])

LOG_DEFAULT_LINES = CONFIG.get("log_default_lines", 200)

app = FastAPI(title="Genesis Admin Agent", version="1.0.0")


# ============================================================
# Seguridad
# ============================================================

def check_token(token: str):
    if not ADMIN_TOKEN:
        raise HTTPException(status_code=500, detail="Token no configurado")
    if token != ADMIN_TOKEN:
        raise HTTPException(status_code=401, detail="Token inválido")


def assert_service_allowed(service: str):
    if service in ALLOWED_EXACT:
        return
    for prefix in ALLOWED_PREFIX:
        if service.startswith(prefix):
            return
    raise HTTPException(
        status_code=403,
        detail=f"Servicio '{service}' NO permitido por política del agente",
    )


def run_command(cmd: list, timeout: int = 20) -> str:
    try:
        res = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            text=True,
            check=False,
        )
        return res.stdout.strip()
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Timeout ejecutando comando")


def get_token_header(x_admin_token: str = Header(..., alias="X-Admin-Token")):
    check_token(x_admin_token)


# ============================================================
# Modelos
# ============================================================

class ServiceActionResponse(BaseModel):
    service: str
    action: str
    success: bool
    output: str


class ServiceStatusResponse(BaseModel):
    service: str
    active: bool
    info: str
    raw_output: str


# ============================================================
# Endpoints
# ============================================================

@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/services", dependencies=[Depends(get_token_header)])
def list_services():
    return {
        "allowed_exact": ALLOWED_EXACT,
        "allowed_prefix": ALLOWED_PREFIX,
    }


@app.post("/service/{service}/start", response_model=ServiceActionResponse, dependencies=[Depends(get_token_header)])
def start_service(service: str):
    assert_service_allowed(service)
    out = run_command(["systemctl", "start", service])
    return ServiceActionResponse(service=service, action="start", success=True, output=out)


@app.post("/service/{service}/stop", response_model=ServiceActionResponse, dependencies=[Depends(get_token_header)])
def stop_service(service: str):
    assert_service_allowed(service)
    out = run_command(["systemctl", "stop", service])
    return ServiceActionResponse(service=service, action="stop", success=True, output=out)


@app.post("/service/{service}/restart", response_model=ServiceActionResponse, dependencies=[Depends(get_token_header)])
def restart_service(service: str):
    assert_service_allowed(service)
    out = run_command(["systemctl", "restart", service])
    return ServiceActionResponse(service=service, action="restart", success=True, output=out)


@app.get("/service/{service}/status", response_model=ServiceStatusResponse, dependencies=[Depends(get_token_header)])
def service_status(service: str):
    assert_service_allowed(service)
    raw = run_command(["systemctl", "status", service, "--no-pager"])
    active = "Active: active" in raw
    info = next((l.strip() for l in raw.splitlines() if "Active:" in l), "unknown")
    return ServiceStatusResponse(service=service, active=active, info=info, raw_output=raw)


@app.get("/service/{service}/logs", dependencies=[Depends(get_token_header)])
def service_logs(service: str, lines: Optional[int] = Query(None, ge=1, le=2000)):
    assert_service_allowed(service)
    n = lines or LOG_DEFAULT_LINES
    raw = run_command(["journalctl", "-u", service, "-n", str(n), "--no-pager"])
    return {"service": service, "lines": n, "logs": raw}


@app.get("/service/{service}/databases", dependencies=[Depends(get_token_header)])
def list_databases(service: str):
    assert_service_allowed(service)
    
    try:
        owner = service.split("odoo-server-")[1]
    except Exception:
        owner = None
        
    if not owner:
        return {"service": service, "databases": [], "error": "No se pudo extraer owner del nombre del servicio"}
    
    sql = f"""
        SELECT datname
        FROM pg_database
        WHERE datistemplate = false
        AND pg_get_userbyid(datdba) = '{owner}';
    """
    
    raw = run_command([
        "sudo", "-u", "postgres",
        "psql", "-Atc",
        sql
    ])

    dbs = [x for x in raw.split("\n") if x.strip()]
    
    return {
        "service": service, 
        "databases": dbs,
        "owner": owner,
    }


@app.get("/service/{service}/modules/{db}", dependencies=[Depends(get_token_header)])
def list_modules(service: str, db: str):
    assert_service_allowed(service)

    raw = run_command([
        "sudo", "-u", "postgres",
        "psql", "-d", db, "-Atc",
        "SELECT name, state FROM ir_module_module WHERE state='installed';"
    ])

    modules = []
    for line in raw.split("\n"):
        if not line.strip():
            continue
        name, state = line.split("|")
        modules.append({
            "name": name, 
            "state": state
        })

    return {
        "service": service, 
        "db": db, 
        "modules": modules
    }
    
    
@app.post("/service/{service}/git/pull", dependencies=[Depends(get_token_header)])
def git_pull(service: str):

    # Extraer owner desde el nombre del servicio
    try:
        owner = service.replace("odoo-server-", "")
    except:
        raise HTTPException(status_code=400, detail="Formato de servicio inválido")

    repo_path = f"/opt/{owner}/odoo-server/modulosFE17"

    output = run_command(["git", "-C", repo_path, "pull"])

    return {
        "service": service,
        "repo": repo_path,
        "output": output,
    }
