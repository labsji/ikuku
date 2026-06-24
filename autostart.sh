#!/bin/bash
# autostart.sh — sourced from .bashrc on WSL2 login
# Shows training status and offers to start. Non-blocking if user just wants a shell.

IKUKU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Only trigger in interactive shells
if [[ $- == *i* ]] && [ -z "$IKUKU_NO_AUTO" ]; then
    # Check if training repo exists
    if [ -d "$HOME/next-sale" ]; then
        PROGRESS=$(grep -c "✅ Done" "$HOME/next-sale/PROGRESS.md" 2>/dev/null || echo "0")
        TOTAL=$(grep -c "^|" "$HOME/next-sale/PROGRESS.md" 2>/dev/null || echo "9")
        echo ""
        echo "  ikuku Training: ${PROGRESS}/${TOTAL} tutorials complete"
        echo "  ERPNext: http://localhost:8000"
        echo "  Git:     http://localhost:3000"
        echo ""
        echo "  → Type 'train' to continue training"
        echo "  → Type anything else for a normal shell"
        echo ""
    else
        echo ""
        echo "  ikuku ready. ERPNext at http://localhost:8000"
        echo "  → Type 'train' to start training"
        echo ""
    fi

    # Add 'train' alias
    alias train="bash $IKUKU_DIR/start-local.sh"
fi
