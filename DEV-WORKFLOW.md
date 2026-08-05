# ikuku Development Workflow

## Principle: Develop on Linux, final test on Windows

```
CloudShell (Linux)                    Windows Spot (shazam)
─────────────────                    ────────────────────
Edit code                            Final .exe build + install test
Run test-ikuku-local.sh              RDP visual check
  ├── activate  (2 sec)              Kiro activation verify
  ├── quick     (30 sec)             Notebook/terminal UI check
  └── full      (10 min)             End-user flow test
Push to CodeCommit                   Pull + rebuild exe
```

## Day-to-day flow

### 1. Edit in CloudShell (free, always on)
```bash
cd ~/ikuku && git checkout kiro-layer
# edit init.sh, install.ps1, etc
```

### 2. Test on Linux (no Windows needed for most changes)
```bash
# Test activation logic only (instant)
bash test-ikuku-local.sh activate

# Test kiro + bind download/extraction (30s)
bash test-ikuku-local.sh quick

# Full stack test with podman-compose (10min first time, 30s restart)
bash test-ikuku-local.sh full
```

### 3. Push when tests pass
```bash
git add -A && git commit -m "description" && git push origin kiro-layer
```

### 4. Windows test (only when needed)
```bash
# Fire spot instance (~5min boot)
cd ~/metal-spot4win && bash shazam.sh

# From Windows SSH: pull latest and rebuild exe
cd C:\Users\Administrator\ikuku && git pull origin kiro-layer
"C:\Program Files (x86)\NSIS\makensis.exe" /DVARIANT=lite /DWLEXENAME=ikuku-kiro ikuku-installer.nsi

# Test the exe install (clean)
ikuku-kiro-lite.exe /S

# Shut down when done
# From CloudShell:
cd ~/metal-spot4win && bash shazam.sh down
```

## What to test where

| Change | Test on Linux | Test on Windows |
|--------|:---:|:---:|
| init.sh logic | ✅ | only if WSL-specific |
| Activation flow | ✅ | ─ |
| bind install/extract | ✅ | ─ |
| docker-compose.yml | ✅ | ─ |
| install.ps1 | ─ | ✅ |
| ikuku-installer.nsi | ─ | ✅ |
| Port mapping/proxy | ─ | ✅ |
| .exe silent install | ─ | ✅ |
| Notebook/terminal UI | ─ | ✅ (RDP) |

## Keeping versions in sync

The CodeCommit `kiro-layer` branch is the single source of truth.

```bash
# CloudShell always has latest
cd ~/ikuku && git pull origin kiro-layer

# Windows pulls on spot boot (add to shazam post-boot or manual)
# From Windows SSH:
cd C:\Users\Administrator\ikuku && git pull origin kiro-layer
```

For the Windows VM to pull from CodeCommit, configure git credential helper:
```cmd
git config --global credential.helper "!aws codecommit credential-helper $@"
git config --global credential.UseHttpPath true
```

Or push to GitHub (`github` remote) and pull from there on Windows.

## S3 artifacts (must stay in sync with code)

```
s3://ikuku-releases/
├── bind/bind.tar.gz    ← rebuild: cd ~/bind && tar czf + aws s3 cp
├── kiro/kiro-cli       ← update: aws s3 cp /usr/local/bin/kiro-cli  (current: 2.15.0)
├── kiro/kiro-cli-chat  ← update: aws s3 cp /usr/local/bin/kiro-cli-chat
└── kiro/kiro-cli-term  ← update: aws s3 cp /usr/local/bin/kiro-cli-term
```

Rebuild bind tar after any bind code change:
```bash
cd ~/bind && git checkout kiro-layer
tar czf /tmp/bind.tar.gz --exclude='.git' --exclude='__pycache__' .
aws s3 cp /tmp/bind.tar.gz s3://ikuku-releases/bind/bind.tar.gz --region ap-south-1
```
