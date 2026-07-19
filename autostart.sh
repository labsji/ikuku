#!/bin/bash
# autostart.sh — sourced from .bashrc on WSL2 terminal open
# Shows training status and sets the `train` alias.
# Non-blocking: exits immediately, doesn't interfere with normal shell use.

IKUKU_DIR="/opt/ikuku"

# Show status line
if podman ps 2>/dev/null | grep -q ikuku_frappe; then
    echo "🟢 ikuku running | http://localhost:8000 | type 'train' to start training"
else
    echo "⚪ ikuku stopped | starting containers..."
    (cd "$IKUKU_DIR" && podman-compose up -d 2>/dev/null &)
fi

# Set train alias
alias train="bash $IKUKU_DIR/start-local.sh"
