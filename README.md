# Talos - Cluster Build Runbook
### NUC10FNH control plane + 4× Protectli FW2B netbooted workers

**Audience:** whoever implements this. Follow §5 top to bottom. Every file you need is in §4 in full; every command is in §5 in execution order.

**Target versions:** Talos Linux **v1.13.6**, Kubernetes 1.35, Flannel CNI (Talos default).

---

## 1. What this builds

| | |
|---|---|
| **Control plane** | 1× Intel NUC10FNH, Talos installed to NVMe, also hosts the netboot stack |
| **Workers** | 4× Protectli FW2B, network boot from the NUC on **every** boot |
| **Boot chain** | router DHCP + NUC proxyDHCP → TFTP iPXE → HTTP iPXE script → HTTP kernel/initramfs → `talos.config` over HTTP |
| **DHCP** | your existing router keeps serving leases; the NUC only adds PXE options |
| **Worker state** | mSATA holds STATE + EPHEMERAL only — no bootloader, no install |
| **Config server security** | source-IP allowlist + access logging on `/config/` |

**Not HA.** One control plane means no etcd quorum. If the NUC is down, the Kubernetes API is down and no worker can boot. That is an accepted tradeoff of this design, not an oversight — see §8.

---

## 2. Hardware constraints you must know before starting

### Protectli FW2B
- **Intel Celeron J3060: 2 cores, 2 threads**, 1.6 GHz / 2.48 GHz turbo. (The quad-core J3160 is the FW4B — do not assume 4 cores.)
- **8 GB DDR3L maximum**, single SO-DIMM. Fit 8 GB in each.
- 1× mSATA + an internal SATA header. 2× Intel i211 1GbE. 2× HDMI. RJ45 serial console at **115200 8N1**.
- Ships with **AMI BIOS or coreboot**. The FW-series coreboot build is **legacy BIOS only with no setup menu** (F11 for a boot menu is all you get). **Use AMI BIOS.** If these units are on coreboot, flash AMI before starting.
- x86-64-v2 is satisfied (Airmont has SSE4.2, POPCNT, CX16), so Talos runs. No blocker.

### Intel NUC10FNH
- Comet Lake, single Intel i219-V NIC, M.2 NVMe + 2.5" SATA bay. Plenty for a control plane.

### The "diskless" caveat

The original ask was fully diskless workers. **Talos does not support that yet** — it requires a STATE partition on a block device to persist machine config and node identity. RAM-only netboot is an open feature request ([talos#11317](https://github.com/siderolabs/talos/issues/11317)); Talos 1.12 shipped only the building blocks (tmpfs volumes).

This runbook implements the closest supported thing: **netboot every boot, mSATA used only for STATE + EPHEMERAL, no bootloader written to disk.** Wipe the mSATA and the node rebuilds itself identically. §7.2 tells you how to test whether true zero-disk works on your units.

If netboot-every-boot turns out to be flaky in your environment, the fallback is to add `machine.install` back to the worker patch and let the nodes install to mSATA, using PXE only for provisioning. That change is one YAML block; everything else in this runbook is unchanged.

---

## 3. Prerequisites and values to fill in

### 3.1 Collect this information first

| Value | Used in | Example / how to get it |
|---|---|---|
| Worker MAC addresses ×4 | router DHCP reservations | sticker on the unit, or the PXE screen on first boot |
| NUC MAC address | router DHCP reservation | boot the Talos ISO, read the dashboard |
| Cluster subnet | everywhere | `192.168.1.0/24` |
| Router / gateway IP | firewall + reservations | `192.168.1.1` |
| NUC IP | everywhere | `192.168.1.210` |
| Worker IPs | nginx allowlist | `192.168.1.211` / `.212` / `.213` / `.214` |
| NUC NVMe device path | `patches/controlplane.yaml` | discovered in step **B3** |
| NUC network interface name | `dnsmasq.conf` | discovered in step **B7** |
| Talos version | asset job | `v1.13.6` |
| Image Factory schematic ID | asset job | `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba` (vanilla) |

### 3.2 Placeholders used in §4

Every file in §4 uses these literal values. If your network differs, change them once:

```bash
# run from the repo root created in step A2, after writing all files
grep -rl '192\.168\.1\.' . | xargs sed -i '' 's/192\.168\.1\./10.0.5./g'   # macOS
# grep -rl '192\.168\.1\.' . | xargs sed -i  's/192\.168\.1\./10.0.5./g'   # Linux
```

| Placeholder | Value in §4 | Also appears in |
|---|---|---|
| Cluster subnet | `192.168.1.0/24` | `dnsmasq.conf` |
| NUC | `192.168.1.210` | `dnsmasq.conf`, `boot.ipxe`, `talosconfig` endpoint |
| Workers | `192.168.1.211-214` | `nginx.conf` allowlist |
| NUC interface | `ENP_PLACEHOLDER` | `dnsmasq.conf` — replaced in step **C1** |
| NUC install disk | `/dev/nvme0n1` | `patches/controlplane.yaml` — verified in step **B3** |

### 3.3 Router preparation — do this before anything else

1. Create **DHCP reservations** for all four MACs at the IPs above.
2. Set the **hostname** in each reservation: `cp-00`, `wn-01`, `wn-02`, `wn-03`, `wn-04`. Talos picks up the DHCP-supplied hostname (option 12), which is why no hostname appears in any machine config below and why all three workers can share one config file.
3. **Verify the router is NOT sending PXE options.** Check that DHCP options 66 (`next-server`) and 67 (`filename`) are unset. Two DHCP servers offering boot files produces intermittent, maddening failures.

### 3.4 Workstation tooling

```bash
# talosctl
curl -sL https://talos.dev/install | sh
talosctl version --client       # expect v1.13.x

# kubectl — any 1.34/1.35 build
kubectl version --client
```

---

## 4. Every file, in full

Create this tree on your workstation:

```
talos-homelab/
├── schematic.yaml
├── patches/
│   ├── controlplane.yaml
│   └── worker.yaml
└── k8s/
    ├── 00-namespace.yaml
    ├── 10-cm-dnsmasq.yaml
    ├── 11-cm-nginx.yaml
    ├── 12-cm-fetch-assets.yaml
    ├── 20-job-fetch-assets.yaml
    ├── 30-deploy-dnsmasq.yaml
    └── 31-deploy-nginx.yaml
```

`talosctl gen config` will later add `controlplane.yaml`, `worker.yaml`, `secrets.yaml`, and `talosconfig` at the root. **Those four contain secrets — see §4.11 before committing anything to git.**

> **Note on `boot.ipxe`:** it is not a file you write. The asset job (§4.8) generates it at fetch time from the kernel command line Image Factory publishes, then appends `talos.config=`. That way the required Talos kernel args — which include IMA and console settings that change between releases — always come from the source of truth instead of a hand-maintained copy. The job prints the generated script to its log so you can inspect it.

---

### 4.1 `schematic.yaml`

Only needed if you want system extensions. Intel microcode is worth having on both platforms.

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/intel-ucode
```

If you skip this, use the vanilla schematic ID `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba` everywhere and don't run step **A3**.

---

### 4.2 `patches/controlplane.yaml`

```yaml
machine:
  install:
    disk: /dev/nvme0n1
cluster:
  allowSchedulingOnControlPlanes: true
```

`allowSchedulingOnControlPlanes` is **required** — dnsmasq and nginx run on this node, and it removes the `node-role.kubernetes.io/control-plane:NoSchedule` taint.

---

### 4.3 `patches/worker.yaml`

```yaml
machine:
  nodeLabels:
    hardware: fw2b
  kubelet:
    extraConfig:
      systemReserved:
        memory: 512Mi
      evictionHard:
        memory.available: 250Mi
  sysctls:
    vm.max_map_count: "262144"
```

**There is deliberately no `machine.install` section.** That is what stops Talos writing a bootloader to the mSATA and hijacking the netboot path on the next reboot.

Note `hardware: fw2b` has no domain prefix on purpose — the NodeRestriction admission plugin blocks a kubelet from self-assigning most `*.kubernetes.io` labels.

---

### 4.4 `k8s/00-namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: netboot
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
```

**Do not omit the labels.** Talos enforces Pod Security Admission at `baseline` for every namespace except `kube-system`. Baseline forbids `hostNetwork`, `hostPath` volumes, and `NET_ADMIN` — all three of which this stack needs. Without these labels every pod below is rejected at admission with no obvious explanation.

---

### 4.5 `k8s/10-cm-dnsmasq.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dnsmasq-config
  namespace: netboot
data:
  dnsmasq.conf: |
    # DNS off — this instance does DHCP/TFTP only
    port=0
    log-dhcp
    interface=ENP_PLACEHOLDER
    bind-interfaces

    # Proxy mode: answer PXE options only, never hand out an address.
    # The router remains the DHCP server.
    dhcp-range=192.168.1.0,proxy
    dhcp-no-override

    # Client architecture tagging
    dhcp-match=set:bios,option:client-arch,0
    dhcp-match=set:efi64,option:client-arch,7
    dhcp-match=set:efi64,option:client-arch,9

    # Detect a request that came from iPXE itself (two ways, same tag)
    dhcp-match=set:ipxe,175
    dhcp-userclass=set:ipxe,iPXE

    # Stage 1 — firmware option ROM chainloads iPXE over TFTP.
    # tag:!ipxe is what prevents an infinite chainload loop.
    pxe-service=tag:!ipxe,tag:bios,x86PC,"chain to iPXE (BIOS)",undionly.kpxe
    pxe-service=tag:!ipxe,tag:efi64,x86-64_EFI,"chain to iPXE (UEFI)",ipxe.efi

    # Stage 2 — iPXE asks again; hand it the HTTP script
    dhcp-boot=tag:ipxe,http://192.168.1.210:8080/boot.ipxe

    enable-tftp
    tftp-root=/var/lib/tftpboot
```

`undionly.kpxe` and `ipxe.efi` are already inside the `quay.io/poseidon/dnsmasq` image at `/var/lib/tftpboot` — nothing to download.

---

### 4.6 `k8s/11-cm-nginx.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: netboot
data:
  nginx.conf: |
    user  nginx;
    worker_processes  1;
    error_log  /dev/stderr warn;
    pid        /var/run/nginx.pid;

    events {
      worker_connections  256;
    }

    http {
      access_log  /dev/stdout;
      sendfile    on;
      server_tokens off;

      server {
        listen 8080 default_server;

        # generated by the asset job, lives alongside the kernel/initramfs
        location = /boot.ipxe {
          alias /srv/assets/boot.ipxe;
          default_type text/plain;
        }

        location /assets/ {
          alias /srv/assets/;
          autoindex on;
        }

        # Machine config contains cluster join tokens.
        # Allowlist the three workers, log every request, deny everything else.
        location /config/ {
          alias /srv/config/;
          allow 192.168.1.211;
          allow 192.168.1.212;
          allow 192.168.1.213;
          allow 192.168.1.214;
          deny  all;
          default_type text/yaml;
          access_log /dev/stdout;
        }
      }
    }
```

The allowlist is not a real authorization boundary — IPs are spoofable and the worker addresses are predictable from DHCP reservations. It converts a drive-by into something deliberate, and the access log tells you when someone tries. §8.3 covers what a stronger boundary would look like.

---

### 4.7 `k8s/12-cm-fetch-assets.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fetch-assets-script
  namespace: netboot
data:
  fetch-assets.sh: |
    #!/bin/sh
    set -eu

    echo "Talos ${TALOS_VERSION}, schematic ${SCHEMATIC}"

    PXE_SCRIPT="$(curl -fsSL --retry 3 \
      "https://pxe.factory.talos.dev/pxe/${SCHEMATIC}/${TALOS_VERSION}/metal-amd64")"

    echo "--- Image Factory iPXE script ---"
    printf '%s\n' "$PXE_SCRIPT"
    echo "---------------------------------"

    KERNEL_LINE="$(printf '%s\n' "$PXE_SCRIPT" | grep '^kernel ' || true)"
    INITRD_LINE="$(printf '%s\n' "$PXE_SCRIPT" | grep '^initrd ' || true)"

    [ -n "$KERNEL_LINE" ] || { echo "FATAL: no kernel line in PXE script"; exit 1; }
    [ -n "$INITRD_LINE" ] || { echo "FATAL: no initrd line in PXE script"; exit 1; }

    KERNEL_URL="$(printf  '%s\n' "$KERNEL_LINE" | awk '{print $2}')"
    INITRD_URL="$(printf  '%s\n' "$INITRD_LINE" | awk '{print $2}')"
    KERNEL_ARGS="$(printf '%s\n' "$KERNEL_LINE" | cut -d' ' -f3-)"

    mkdir -p "$DEST"

    # download to .tmp then rename, so a failed fetch can't brick netboot
    curl -fsSL --retry 3 -o "${DEST}/vmlinuz-amd64.tmp"      "$KERNEL_URL"
    curl -fsSL --retry 3 -o "${DEST}/initramfs-amd64.xz.tmp" "$INITRD_URL"
    mv "${DEST}/vmlinuz-amd64.tmp"      "${DEST}/vmlinuz-amd64"
    mv "${DEST}/initramfs-amd64.xz.tmp" "${DEST}/initramfs-amd64.xz"

    # Generate boot.ipxe using Image Factory's own kernel args, plus ours.
    # \${base} is escaped so the shell leaves it for iPXE to expand.
    cat > "${DEST}/boot.ipxe" <<EOF
    #!ipxe
    :retry
    dhcp || goto retry
    set base ${BASE_URL}
    kernel \${base}/assets/vmlinuz-amd64 ${KERNEL_ARGS} console=ttyS0,115200n8 talos.config=\${base}/config/worker.yaml || goto retry
    initrd \${base}/assets/initramfs-amd64.xz || goto retry
    boot || goto retry
    EOF

    echo "--- generated boot.ipxe ---"
    cat "${DEST}/boot.ipxe"
    echo "---------------------------"
    ls -l "$DEST"
    echo "assets ready"
```

What this does and why:

- Asks Image Factory for the iPXE script and **parses the real kernel/initrd URLs out of it** rather than hardcoding paths that may change.
- Reuses **Image Factory's own kernel command line** verbatim. That line carries the three required args (`talos.platform=metal`, `slab_nomerge`, `pti=on`) plus release-specific ones — IMA settings, `nvme_core.io_timeout`, `printk.devkmsg`, and so on. Copying them by hand is how you end up with a subtly wrong boot on the next Talos release.
- Appends only what's ours: `console=ttyS0,115200n8` for the FW2B serial console, and `talos.config=` pointing at the NUC.
- The `goto retry` loop makes a power outage self-healing — workers spin until the NUC finishes coming up.
- Downloads to `.tmp` and renames, so an interrupted fetch can't leave a truncated kernel in place.

> The heredoc body must stay indented consistently with the rest of the block (YAML block scalar), and the closing `EOF` must line up with it. If you retype this by hand, watch that.

---

### 4.8 `k8s/20-job-fetch-assets.yaml`

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: fetch-assets
  namespace: netboot
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        app: fetch-assets
    spec:
      restartPolicy: OnFailure
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      securityContext:
        runAsUser: 0
      containers:
        - name: fetch
          image: docker.io/curlimages/curl:8.11.1
          command: ["/bin/sh", "/scripts/fetch-assets.sh"]
          env:
            - name: TALOS_VERSION
              value: "v1.13.6"
            - name: SCHEMATIC
              value: "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
            - name: DEST
              value: "/assets"
            - name: BASE_URL
              value: "http://192.168.1.210:8080"
          volumeMounts:
            - name: scripts
              mountPath: /scripts
            - name: assets
              mountPath: /assets
      volumes:
        - name: scripts
          configMap:
            name: fetch-assets-script
        - name: assets
          hostPath:
            path: /var/lib/netboot/assets
            type: DirectoryOrCreate
```

`runAsUser: 0` is needed because `curlimages/curl` runs as UID 100 and the hostPath is root-owned.

`/var/lib/netboot` works as a hostPath because `/var` is Talos's writable EPHEMERAL mount. Nothing else on a Talos node is writable.

---

### 4.9 `k8s/30-deploy-dnsmasq.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dnsmasq
  namespace: netboot
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: dnsmasq
  template:
    metadata:
      labels:
        app: dnsmasq
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: dnsmasq
          image: quay.io/poseidon/dnsmasq:latest
          args:
            - "-d"                                    # foreground
            - "-q"                                    # log queries
            - "--conf-file=/etc/dnsmasq/dnsmasq.conf"
          securityContext:
            capabilities:
              add: ["NET_ADMIN", "NET_RAW", "NET_BIND_SERVICE"]
          volumeMounts:
            - name: config
              mountPath: /etc/dnsmasq
      volumes:
        - name: config
          configMap:
            name: dnsmasq-config
```

> **Pin the image tag before handing this to production.** `:latest` is used here only because tag lists change. Find a real tag and pin it:
> ```bash
> crane ls quay.io/poseidon/dnsmasq | tail -5
> # or browse https://quay.io/repository/poseidon/dnsmasq?tab=tags
> ```

`strategy: Recreate` matters — two dnsmasq pods cannot both bind UDP/67 on the host, so a rolling update would deadlock.

---

### 4.10 `k8s/31-deploy-nginx.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: netboot
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: nginx
          image: docker.io/library/nginx:1.27-alpine
          ports:
            - containerPort: 8080
              hostPort: 8080
          volumeMounts:
            - name: nginx-config
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
            - name: assets
              mountPath: /srv/assets
              readOnly: true
            - name: config
              mountPath: /srv/config
              readOnly: true
          readinessProbe:
            httpGet:
              path: /boot.ipxe
              port: 8080
            initialDelaySeconds: 3
      volumes:
        - name: nginx-config
          configMap:
            name: nginx-config
        - name: assets
          hostPath:
            path: /var/lib/netboot/assets
            type: DirectoryOrCreate
        - name: config
          secret:
            secretName: machine-config
            defaultMode: 0444
```

The readiness probe hits `/boot.ipxe`, which only exists once the asset job has run — so nginx will not report Ready until the netboot assets are actually in place. That's intentional.

---

### 4.11 The `machine-config` Secret

Created imperatively in step **C4**, because it holds `worker.yaml` — which contains `machine.token` and `cluster.token`. Do not commit it.

Add to `.gitignore`:

```gitignore
secrets.yaml
talosconfig
controlplane.yaml
worker.yaml
kubeconfig
```

---

## 5. Build procedure

Run these in order. Do not skip ahead — several steps produce values later steps need.

### Phase A — Workstation: generate configs

**A1.** Complete §3.3 (router reservations, hostnames, no PXE options). Confirm before continuing.

**A2.** Create the repo and write every file from §4:

```bash
mkdir -p talos-homelab/{patches,k8s}
cd talos-homelab
git init
# write all files from §4 now
```

**A3.** *(Optional — skip if using the vanilla schematic.)* Register the schematic and record the ID:

```bash
curl -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics
# → {"id":"<schematic-id>"}
```

Put that ID into `k8s/20-job-fetch-assets.yaml` (`SCHEMATIC` env var).

**A4.** Generate secrets separately so config generation is reproducible:

```bash
talosctl gen secrets -o secrets.yaml
```

**A5.** Generate the machine configs with both patches applied in one shot:

```bash
talosctl gen config homelab https://192.168.1.210:6443 \
  --with-secrets secrets.yaml \
  --config-patch-control-plane @patches/controlplane.yaml \
  --config-patch-worker @patches/worker.yaml \
  --with-docs=false \
  --with-examples=false \
  --output-dir .
```

Produces `controlplane.yaml`, `worker.yaml`, `talosconfig`.

**A6.** Sanity-check the two things most likely to be wrong:

```bash
grep -A2 'install:' controlplane.yaml        # expect disk: /dev/nvme0n1
grep -c 'install:' worker.yaml               # expect 0 — no install section
grep 'allowSchedulingOnControlPlanes' controlplane.yaml   # expect true
```

**A7.** Download the ISO for the NUC (same version and schematic as the workers):

```bash
curl -LO https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.13.6/metal-amd64.iso
```

Write it to USB (`dd`, Rufus, balenaEtcher — whatever you like).

---

### Phase B — NUC: install Talos and bootstrap the cluster

**B1.** Boot the NUC from the USB stick. It comes up in **maintenance mode** and displays its DHCP address on the console dashboard. It should match your reservation (`192.168.1.210`).

**B2.** Point talosctl at it:

```bash
export TALOSCONFIG=$PWD/talosconfig
talosctl config endpoint 192.168.1.210
talosctl config node 192.168.1.210
```

**B3.** **Confirm the install disk** before applying anything:

```bash
talosctl -n 192.168.1.210 get disks --insecure
```

If the NVMe is not `/dev/nvme0n1`, fix `patches/controlplane.yaml` and re-run **A5**.

**B4.** Apply the control-plane config. The node installs to NVMe and reboots.

```bash
talosctl apply-config --insecure -n 192.168.1.210 -f controlplane.yaml
```

**B5.** Wait for it to come back (2–5 minutes), then bootstrap etcd. **Run this exactly once, ever.**

```bash
talosctl -n 192.168.1.210 bootstrap
```

**B6.** Fetch kubeconfig and confirm the node is up:

```bash
talosctl -n 192.168.1.210 kubeconfig ./kubeconfig
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide     # cp-00 Ready (may take a few minutes)
```

**B7.** **Discover the NUC's interface name** — you need it for dnsmasq:

```bash
talosctl -n 192.168.1.210 get links -o json | grep -i '"id"' | head -20
# or, more readable:
talosctl -n 192.168.1.210 get addresses
```

Look for the physical link carrying `192.168.1.210` — typically `enp0s31f6` on a NUC10. Record it.

---

### Phase C — Deploy the netboot stack

**C1.** Substitute the interface name discovered in B7:

```bash
sed -i '' 's/ENP_PLACEHOLDER/enp0s31f6/' k8s/10-cm-dnsmasq.yaml   # macOS
# sed -i  's/ENP_PLACEHOLDER/enp0s31f6/' k8s/10-cm-dnsmasq.yaml   # Linux
grep interface= k8s/10-cm-dnsmasq.yaml    # verify
```

**C2.** Apply the namespace first, on its own — PSA labels must exist before any pod is admitted:

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl get ns netboot --show-labels    # expect pod-security.kubernetes.io/enforce=privileged
```

**C3.** Apply the ConfigMaps:

```bash
kubectl apply -f k8s/10-cm-dnsmasq.yaml \
               -f k8s/11-cm-nginx.yaml \
               -f k8s/12-cm-fetch-assets.yaml
```

**C4.** Create the machine-config Secret from the generated worker config:

```bash
kubectl -n netboot create secret generic machine-config \
  --from-file=worker.yaml=./worker.yaml
```

**C5.** Fetch the boot assets and **read the job log** — it prints both the Image Factory script it parsed and the `boot.ipxe` it generated:

```bash
kubectl apply -f k8s/20-job-fetch-assets.yaml
kubectl -n netboot wait --for=condition=complete job/fetch-assets --timeout=300s
kubectl -n netboot logs job/fetch-assets
```

Check three things in that log:

1. `vmlinuz-amd64` (~15 MB) and `initramfs-amd64.xz` (~80 MB) in the final listing.
2. The generated `boot.ipxe` contains `talos.platform=metal`, `slab_nomerge`, and `pti=on`.
3. It ends with `talos.config=${base}/config/worker.yaml` — with `${base}` **unexpanded**. If the shell ate it, the heredoc escaping got mangled during transcription.

If the job fails, nothing downstream works. Fix it here before continuing.

**C6.** Start the two services:

```bash
kubectl apply -f k8s/30-deploy-dnsmasq.yaml -f k8s/31-deploy-nginx.yaml
kubectl -n netboot rollout status deploy/dnsmasq
kubectl -n netboot rollout status deploy/nginx
```

**C7.** **Verify from your workstation before touching any FW2B.** This is the checkpoint that saves you from debugging two layers at once:

```bash
# iPXE script is served
curl -s http://192.168.1.210:8080/boot.ipxe

# kernel and initramfs are present and non-trivial in size
curl -sI http://192.168.1.210:8080/assets/vmlinuz-amd64      | head -3
curl -sI http://192.168.1.210:8080/assets/initramfs-amd64.xz | head -3

# config server correctly REFUSES your workstation (expect 403)
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.210:8080/config/worker.yaml
```

A `403` on that last command means the allowlist works. A `200` means your workstation is inside the allowlist — check the IPs in `nginx.conf`.

**C8.** Leave a log tail running in a second terminal for Phase E:

```bash
kubectl -n netboot logs -f deploy/dnsmasq
```

---

### Phase D — FW2B firmware (physical access, all three units)

Attach a monitor to HDMI, or a serial console at **115200 8N1** over the RJ45 COM port.

**D1.** Power on, press `Delete` repeatedly to enter AMI BIOS setup.

**D2.** **Advanced → CSM Configuration → Network → Legacy**. This is what makes the i211 ports appear as bootable devices. Without it there is no PXE option at all.

**D3.** `F4` → **Save & Exit** → Yes. The unit reboots.

**D4.** Re-enter setup. In **Boot**, set **network as the first boot device**, and **disable or remove the mSATA boot entry**. Removing the disk entry is belt-and-braces against a stray install taking over the boot path.

**D5.** Internally, close the **`JPWR`** jumper so the unit powers on automatically when power is restored. Without it, a power cut means walking to the closet and pressing three buttons.

**D6.** **Cable only ONE NIC** — the port labeled `WAN`. Leave `LAN` unplugged. The `${mac}` substitution in `talos.config` resolves to *"the MAC address of the first network interface attaining link state up"*, which is a coin flip with both ports patched in.

Repeat D1–D6 for all three units.

---

### Phase E — Bring up the first worker

Do **one node only**, and watch it. If it works, the other two are copy-paste.

**E1.** Power on `wn-01`. On the dnsmasq log tail from C8 you should see, in order:

```
DHCPDISCOVER(enp0s31f6) aa:bb:cc:dd:ee:01
PXE(enp0s31f6) aa:bb:cc:dd:ee:01 proxy
...  undionly.kpxe
sent /var/lib/tftpboot/undionly.kpxe to 192.168.1.211
DHCPDISCOVER(enp0s31f6) aa:bb:cc:dd:ee:01          <- now from iPXE
... http://192.168.1.210:8080/boot.ipxe
```

**E2.** Then in the nginx log:

```bash
kubectl -n netboot logs -f deploy/nginx
```

Expect `GET /boot.ipxe`, `GET /assets/vmlinuz-amd64`, `GET /assets/initramfs-amd64.xz`, `GET /config/worker.yaml` — all `200`, all from `192.168.1.211`.

**E3.** Watch it join:

```bash
kubectl get nodes -w
```

`wn-01` should appear and reach `Ready` within a few minutes of the config fetch.

**E4.** Confirm what actually got provisioned on the mSATA:

```bash
talosctl -n 192.168.1.210 get volumestatus
talosctl -n 192.168.1.210 dmesg | tail -50
```

**E5.** **The critical test — reboot it and confirm it netboots again**, rather than booting from disk:

```bash
kubectl -n netboot logs -f deploy/nginx &     # keep watching
talosctl -n 192.168.1.210 reboot
```

A fresh `GET /config/worker.yaml` in the nginx log means netboot-every-boot is working. **No fetch means the node booted from disk** — see §7.1.

---

### Phase F — Remaining workers

**F1.** Power on `wn-02`, `wn-03` and `wn-04`. No per-node configuration required — same `worker.yaml`, hostnames from DHCP reservations.

**F2.** Final state check:

```bash
kubectl get nodes -o wide
talosctl -n 192.168.1.210 health --wait-timeout 10m
```

Expect four nodes `Ready`: `cp-00` (control-plane) and `wn-01/02/03/04`.

**F3.** Commit the repo — **without** the files listed in §4.11.

```bash
git add . && git status     # confirm no secrets.yaml / worker.yaml / talosconfig
git commit -m "talos netboot cluster"
```

Store `secrets.yaml` and `talosconfig` in a password manager. They are not regenerable.

---

## 6. Post-build verification

```bash
# all four nodes healthy
kubectl get nodes -o wide

# Talos-level health
talosctl -n 192.168.1.210 health --wait-timeout 10m

# workers have the expected label and no install section took effect
kubectl get nodes -l hardware=fw2b
talosctl -n 192.168.1.211,192.168.1.212,192.168.1.213,192.168.1.214 get volumestatus

# netboot stack running on the control plane only
kubectl -n netboot get pods -o wide

# config server still refuses non-workers
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.210:8080/config/worker.yaml   # 403

# schedule something and confirm it lands
kubectl create deployment nginx-test --image=nginx:alpine --replicas=3
kubectl get pods -o wide
kubectl delete deployment nginx-test
```

---

## 7. Troubleshooting

| Symptom | Cause | Check |
|---|---|---|
| `PXE-E53: No boot filename received` | proxyDHCP not answering | dnsmasq logs; is `interface=` correct (step C1)? Is the pod `hostNetwork`? |
| No PXE device in the FW2B boot menu | CSM Network not set to Legacy | Redo step **D2** |
| iPXE loads, then loads iPXE again, forever | missing `tag:!ipxe` on `pxe-service` | `k8s/10-cm-dnsmasq.yaml` |
| iPXE: `Connection timed out (http://…:8080)` | nginx not reachable on host network | `kubectl -n netboot get pods -o wide`; `curl` from workstation |
| iPXE: `Error 0x3f...` fetching kernel | asset job never completed | `kubectl -n netboot logs job/fetch-assets` |
| Node boots to Talos maintenance dashboard | config fetch failed | nginx log — 403 means the node IP isn't in the allowlist; 404 means the Secret key isn't `worker.yaml` |
| `403` on `/config/worker.yaml` from a worker | DHCP gave it an unexpected address | Check the router reservation actually applied |
| Pods rejected: `violates PodSecurity "baseline"` | namespace labels missing | Redo step **C2** |
| Node joins, then boots from disk on reboot | an install happened | §7.1 |
| dnsmasq pod `CrashLoopBackOff`, "address already in use" | old pod still holds UDP/67 | `strategy: Recreate` is set; if stuck, scale to 0 then 1 |
| nginx never becomes Ready | asset job hasn't produced `boot.ipxe` | readiness probe hits `/boot.ipxe` by design — rerun step **C5** |

### 7.1 If a worker stops netbooting

Symptom: after a reboot, nginx logs no `/config/worker.yaml` fetch, but the node comes up anyway. Something wrote a bootloader to the mSATA.

1. Confirm the served config has no install section:
   ```bash
   kubectl -n netboot get secret machine-config -o jsonpath='{.data.worker\.yaml}' \
     | base64 -d | grep -c 'install:'      # expect 0
   ```
2. Confirm the mSATA is not in the BIOS boot order (step **D4**).
3. Wipe and let it rebuild:
   ```bash
   talosctl -n 192.168.1.210 reset --graceful=false --reboot \
     --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL
   ```
4. If it keeps installing, accept the fallback: add `machine.install: {disk: /dev/sda}` to `patches/worker.yaml`, regenerate (**A5**), update the Secret (**C4**), and set the BIOS boot order to disk-first / network-fallback. You lose netboot-every-boot; you keep everything else.

### 7.2 Testing whether true zero-disk works

Curiosity satisfied cheaply: pull the mSATA out of `wn-03` and boot it. If it joins and reaches `Ready`, your Talos build tolerates a diskless worker. If it hangs in maintenance mode, you've confirmed the STATE requirement from §2 and the current design is the right one.

---

## 8. Day-2 operations

### 8.1 Upgrading Talos on the workers — it's just a reboot

```bash
# 1. bump the version
sed -i '' 's/v1.13.6/v1.13.7/' k8s/20-job-fetch-assets.yaml

# 2. re-run the asset job
kubectl -n netboot delete job fetch-assets
kubectl apply -f k8s/20-job-fetch-assets.yaml
kubectl -n netboot wait --for=condition=complete job/fetch-assets --timeout=300s

# 3. roll the workers one at a time
for ip in 192.168.1.211 192.168.1.212 192.168.1.213 192.168.1.214; do
  kubectl drain "$(kubectl get node -o name | grep "${ip##*.}")" --ignore-daemonsets --delete-emptydir-data || true
  talosctl -n "$ip" reboot
  sleep 120
  kubectl get nodes
done
```

This is the payoff of netboot-every-boot: no per-node upgrade orchestration, no installer images.

### 8.2 Upgrading the control plane — normal Talos upgrade

```bash
talosctl -n 192.168.1.210 upgrade \
  --image factory.talos.dev/installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.13.7
```

The installer schematic **must match** the schematic used for the boot assets.

### 8.3 Backups — do this before you need it

```bash
talosctl -n 192.168.1.210 etcd snapshot etcd-$(date +%F).db
```

Single control plane means no quorum to save you. The three things that make a rebuild a 30-minute job instead of starting over:

1. `secrets.yaml`
2. `talosconfig`
3. a recent etcd snapshot

Schedule the snapshot. Store all three off the cluster.

### 8.4 Rebuilding a worker from scratch

```bash
talosctl -n 192.168.1.212 reset --graceful=false --reboot \
  --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL
```

It netboots, refetches `worker.yaml`, and rejoins. Nothing to reinstall.

### 8.5 Hardening beyond the allowlist

The nginx allowlist is a speed bump, not a boundary. In rough order of cost:

1. **VLAN the cluster.** Node ports must be **untagged access ports** — the i211 option ROM has no 802.1Q awareness and stage-1 iPXE DHCPs untagged, so a tagged trunk means DHCP silently finds nothing. Firewall LAN→cluster down to tcp/6443 and tcp/50000; explicitly deny tcp/8080, udp/69, udp/67.
2. **Bind nginx to the cluster VLAN address** (`listen 192.168.20.10:8080`) once the NUC has more than one address. Set `net.ipv4.ip_nonlocal_bind: "1"` in the control plane's `machine.sysctls`, or nginx will crashloop when it starts before the address is up.
3. **`talos.config.auth.*` OAuth2** for authenticated config delivery. The designed-for-this answer, but it means depending on an OIDC provider.

HTTPS is deliberately not on that list: the URL is published in plaintext inside `boot.ipxe`, and there's no client authentication, so anyone who can reach the port can still just fetch it. Confidentiality in transit isn't the problem here — authorization is.

**What's actually exposed:** `talosctl gen config` strips CA private keys from worker configs. What leaks is `machine.token` and `cluster.token` — enough to join a rogue worker, not enough to mint certificates. And because the NUC is a disk install, `controlplane.yaml` (which does hold `machine.ca.key`, `cluster.ca.key`, `cluster.serviceAccount.key`, `cluster.secretboxEncryptionSecret`) never crosses the network. **Never PXE-serve a control-plane config.**

---

## 9. Risk register

1. **Cold-start dependency.** The NUC must be fully up — Talos, kubelet, dnsmasq, nginx — before any worker can boot. The `goto retry` loop in `boot.ipxe` makes this self-healing, but expect several minutes of apparent hanging on worker consoles after a power outage. `JPWR` closed (step D5) means you don't have to press any buttons.
2. **Single control plane.** No etcd quorum. NUC down = API down = no worker can boot. §8.3 is the mitigation.
3. **8 GB RAM ceiling on workers.** Talos 1.12+ ships a userspace OOM handler that evicts on memory pressure, which beats the kernel OOM killer, but it isn't magic. Set requests and limits on everything scheduled to these nodes.
4. **2 cores per worker.** Don't run etcd, Longhorn, Ceph, or databases on the FW2Bs. Pin stateful workloads to the NUC with a nodeSelector.
5. **Config server on plain HTTP.** §8.5.
6. **Router is a dependency.** Losing DHCP reservations means workers get wrong IPs, fail the nginx allowlist, and fail to boot. Back up your router config.

---

## Sources

- [Talos v1.13.6 release](https://github.com/siderolabs/talos/releases/tag/v1.13.6)
- [Talos PXE guide](https://docs.siderolabs.com/talos/v1.11/platform-specific-installations/bare-metal-platforms/pxe)
- [Talos kernel parameters reference](https://docs.siderolabs.com/talos/v1.13/reference/kernel)
- [Talos Image Factory](https://docs.siderolabs.com/talos/v1.13/learn-more/image-factory)
- [What's New in Talos 1.12](https://docs.siderolabs.com/talos/v1.12/getting-started/what's-new-in-talos)
- [Talos VLANConfig reference](https://docs.siderolabs.com/talos/v1.13/reference/configuration/network/vlanconfig)
- [Talos networking configuration overview](https://docs.siderolabs.com/talos/v1.13/networking/configuration/overview)
- [siderolabs/talos#11317 — RAM-only netboot (open)](https://github.com/siderolabs/talos/issues/11317)
- [poseidon/dnsmasq container image](https://github.com/poseidon/dnsmasq)
- [Protectli FW2B datasheet](https://protectli.com/wp-content/uploads/2025/02/FW2B-Datasheet-20250124.pdf)
- [Protectli KB — How to Enable PXE on the Vault](https://kb.protectli.com/kb/how-to-enable-pxe-on-the-vault/)
- [Protectli KB — coreboot information](https://kb.protectli.com/kb/coreboot-information/)
- [Celeron J3060 — WikiChip](https://en.wikichip.org/wiki/intel/celeron/j3060)
