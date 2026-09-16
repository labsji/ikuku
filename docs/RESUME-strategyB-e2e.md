# Resume note — Strategy B e2e (updated session 2)

## BIG WIN this session: nested virtualization on non-metal on-demand WORKS

AWS launched (Feb 2026) **nested virtualization on non-metal EC2** (C8i/M8i/R8i). This
fixes BOTH prior blockers: **on-demand = no spot reclamation**, and **Nitro passes VT-x
through** so KVM-accelerated QEMU + WSL2 run stably (no more triple-nest instability).

Proven on **m8i.4xlarge on-demand** (`--cpu-options NestedVirtualization=enabled`):
`/dev/kvm` present, `vmx` on all threads, QEMU `-enable-kvm` works, Win11 booted with
TPM2+SecureBoot, WSL2 kernel installed, `HypervisorPresent=True`, sshd reachable.

### CLI requirement
The `NestedVirtualization` CpuOptions field needs a **recent aws-cli**. Sandbox default
2.33.15 REJECTS it. Installed **`/usr/local/bin/aws` 2.36.46** — use that for launches.

## REUSABLE SNAPSHOT OUTPUTS (region ap-south-1) — the e2e-resumption artifacts

| Snapshot | What | Use |
|---|---|---|
| `snap-0ea50c0ccaf05cf0f` | **Pristine Win11 25H2** clean powered-off (sshd auto + WSL2 kernel MSI, pre-update-storm), qcow2 verified clean | The clean **pristine-Win11 base** for this nested-virt architecture |
| `snap-0d425b641b414f4bb` | **WSL-ready Win11** (sshd + WSL2 kernel + Windows Update & Defender DISABLED). NO Ubuntu distro yet. Also carries win11.iso + virtio.iso | Best base to resume from — WU won't storm |
| `snap-0d828b4d399e1c639` | Fresh Win11 (mid-servicing, backup) | fallback |

All tagged `shazam-vm=win11-fresh, shazam-role=data`. The qcow2 inside each is at
**`/data/win11-fresh.qcow2`** (60G virtual, ~19G actual), creds **Administrator/Admin2026**,
computername WIN11-DEV.

Older kit/pristine snapshots still valid: `snap-0ac2be7dcb8601f8d` (win-ikuku 150G = both
kits kit-alsouk+kit-kapadiwala+bkit+build-layers-b.sh+apply-layers.sh), `snap-0634baa70563957f7`
(old pristine, DO NOT USE — its win11.qcow2 is Cascade-Lake-built, HLT-stalls on m8i).

## THE m8i BOOT RECIPE (critical — write exactly this)

```bash
# swtpm TPM2 (single ctrl socket)
systemd-run --unit=win11tpm swtpm socket --tpmstate dir=/run/win11tpm \
  --ctrl type=unixio,path=/run/win11tpm/swtpm-sock --tpm2 --flags not-need-init
# secure-boot VARS copy (MS keys)
cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd /data/OVMF_VARS_win11.fd

qemu-system-x86_64 -enable-kvm -m 32G -smp 12 -cpu host \
  -machine q35,smm=on -global ICH9-LPC.disable_s3=1 \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,format=raw,unit=1,file=/data/OVMF_VARS_win11.fd \
  -chardev socket,id=chrtpm,path=/run/win11tpm/swtpm-sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
  -drive file=/data/win11-fresh.qcow2,format=qcow2,if=virtio,cache=none,aio=native,discard=unmap \
  -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::3389-:3389 \
  -device virtio-net-pci,netdev=net0 -device virtio-net... \
  -vga qxl -display none -vnc :0 -device usb-ehci -device usb-tablet \
  -monitor unix:/tmp/qemu-mon-ikuku.sock,server,nowait \
  -qmp unix:/tmp/qemu-qmp-ikuku.sock,server,nowait &
```

**CRITICAL boot gotchas learned:**
- **NO `kernel-irqchip=split`** — that metal-era flag causes a HLT-stall boot hang on m8i.
- **TPM2 + SecureBoot are REQUIRED** by Win11 25H2 setup (q35,smm=on + secboot OVMF + swtpm).
- Win11 build 26200's inbox `wsl --install` stub is flaky → install WSL2 via **direct MSI**
  (github.com/microsoft/WSL latest `*.x64.msi` → msiexec /qn) then reboot.
- Guest access: SSH `sshpass -p Admin2026 ssh -p 2222 Administrator@localhost`; VNC :5900;
  QMP screendump to a ppm for screen inspection. Use base64-encoded winps for PS.

## THE MAIN LESSON: Windows Update is the enemy in QEMU

A fresh Win11 25H2 runs a huge cumulative-update finalization on first boots — multi-pass,
multi-reboot, and it repeatedly landed in **Automatic Repair** in QEMU and pegged CPU
~1000% for a very long time, starving SSH. **On next session: FIRST thing after boot,
disable Windows Update + Defender realtime + WSearch + SysMain BEFORE doing anything else**
(the `snap-0d425b641b414f4bb` snapshot already has WU/Defender disabled). Commands:
```
Stop-Service wuauserv,UsoSvc,WaaSMedicSvc,DoSvc -Force; Set-Service ... -StartupType Disabled
Set-MpPreference -DisableRealtimeMonitoring $true
Stop-Service WSearch,SysMain -Force; Set-Service ... -StartupType Disabled
reg: HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU NoAutoUpdate=1
```

## Also: 16G RAM was too little
The first install used `-m 16G` and thrashed. Use **`-m 32G -smp 12`** minimum. A bigger
instance (m8i.8xlarge = 32 vCPU/128G, or c8i) gives more headroom and is what we're moving to.

## NEXT SESSION TODO
1. `/usr/local/bin/aws` — launch a **bigger** on-demand nested-virt instance
   (`m8i.8xlarge` or `m8i.12xlarge`, `--cpu-options NestedVirtualization=enabled`).
2. Attach a volume from **`snap-0d425b641b414f4bb`** (WSL-ready) → mount /data → boot the
   qcow2 with the recipe above (32G+/12+ vCPU).
3. Confirm WU/Defender still disabled; if the box storms, disable again first.
4. `wsl --install -d Ubuntu` (or import an Ubuntu rootfs tarball directly to avoid the
   Store fetch) → confirm `wsl -l -v` shows Ubuntu Running.
5. Attach the kits volume from `snap-0ac2be7dcb8601f8d`, then run the Strategy-B e2e:
   copy kit-alsouk into WSL Ubuntu, run apply-layers.sh (podman load + volume import +
   overlay) → ERPNext 200 + niche Kiro; then kit-kapadiwala → cache HIT on app-images+kiro.
6. Snapshot the final **WSL-with-Ubuntu-distro** state as the definitive reusable base.

## Host DNS gotcha (recurs on every fresh host)
`systemd-resolved` is often broken → fix early: `printf 'nameserver 169.254.169.253\n' >
/etc/resolv.conf` + add hostname to /etc/hosts.
