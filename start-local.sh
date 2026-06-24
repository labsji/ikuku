#!/bin/bash
# start-local.sh — Launches Kiro-led training on local ikuku (no CloudShell).
# Run inside WSL2 or the frappe container.
set -e

REPO_URL="http://trainer:trainer123@localhost:3000/trainer/next-sale.git"
WORK_DIR="${HOME}/next-sale"

# Clone or pull training repo from local gitea
if [ ! -d "$WORK_DIR" ]; then
    echo "Cloning training repo from local gitea..."
    git clone "$REPO_URL" "$WORK_DIR"
else
    cd "$WORK_DIR" && git pull -q origin main 2>/dev/null || true
fi

cd "$WORK_DIR"

# Determine current tutorial from PROGRESS.md
PROGRESS=$(cat PROGRESS.md 2>/dev/null || echo "")
NEXT_NUM=$(echo "$PROGRESS" | grep -oP '^\| \K[0-9]+(?=.*Not Started)' | head -1)
if [ -z "$NEXT_NUM" ]; then
    NEXT_NUM=$(echo "$PROGRESS" | grep -oP '^\| \K[0-9]+(?=.*In Progress)' | head -1)
fi
TUTORIAL_NUM="${NEXT_NUM:-1}"
PADDED=$(printf "%02d" "$TUTORIAL_NUM")
TUTORIAL_FILE=$(ls tutorials/${PADDED}-*.md 2>/dev/null | head -1)

# Write instruction file for Kiro
cat > .kiro-instructions.md << EOF
# Your Role
You are a sales trainer for ERPNext resellers. The delegate is a commerce graduate — NOT technical.

# Current Task
Deliver Tutorial ${TUTORIAL_NUM}. The content is in the file: ${TUTORIAL_FILE}

# Rules
1. Read ${TUTORIAL_FILE} now. Deliver it section by section.
2. TEACH each concept, then ASK one question, WAIT for response.
3. When you reach the Hands-On section, give the delegate the EXACT URLs and steps. ERPNext is at http://localhost:8000 (login: Administrator / admin).
4. After quiz + hands-on are done, update PROGRESS.md: change tutorial ${TUTORIAL_NUM} status to '✅ Done'. Then run: git add PROGRESS.md && git commit -m "T${TUTORIAL_NUM} done" && git push
5. Then say: "Great work! Type /exit and come back for the next topic."
6. If delegate says "feedback: ..." — append to PROGRESS.md under Notes. Say "Got it, noted." Then git add/commit/push.
7. Every few interactions, silently run: git add PROGRESS.md && git commit -m "progress" && git push (don't mention this to delegate).
8. If delegate says "go to tutorial N" — do it. Read that file instead.
9. At the END of each response, include: *(Tip: Shift+PgUp to scroll up, Shift+Enter for multi-line)*
10. When the delegate says something insightful, note it in PROGRESS.md under Notes with prefix "INSIGHT T{N}:" and briefly acknowledge.

# Style
Warm, conversational, encouraging. Like a senior colleague having a coffee chat on your first day.
Greet the delegate warmly when you start. Introduce yourself as their sales training companion.
One question at a time. Never rush. Celebrate good answers.
EOF

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Training: Tutorial ${TUTORIAL_NUM}              ║"
echo "║  ERPNext:  http://localhost:8000         ║"
echo "║  Git:      http://localhost:3000         ║"
echo "╚══════════════════════════════════════════╝"
echo ""

kiro-cli chat --trust-all-tools "Read the file .kiro-instructions.md and follow it exactly. Start by greeting the delegate warmly. Then read ${TUTORIAL_FILE} and deliver Tutorial ${TUTORIAL_NUM} step by step."
