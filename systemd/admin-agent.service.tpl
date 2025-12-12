[Unit]
Description=Genesis Admin Agent
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/genesis-admin-agent
ExecStart=/opt/genesis-admin-agent/venv/bin/uvicorn agent.main:app --host 0.0.0.0 --port 8010
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
