# Talos cluster build runbook
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
| **Agent Substrate** (§10) | control plane + Valkey on the NUC; WorkerPool pinned to FW2Bs only |
| **Snapshot store** (§10) | RustFS on the DGX Spark, reached over S3 |

**Not HA.** One control plane means no etcd quorum. If the NUC is down, the Kubernetes API is down and no worker can boot. That is an accepted tradeoff of this design, not an oversight — see §8.

```

                         +----------------------+
                         | router / gateway     |
                         | 10.0.2.1             |
                         | DHCP server          |
                         +----------+-----------+
                                    |
                                    | LAN 10.0.2.0/24
                                    |
          +-------------------------+-------------------------+
          |                                                   |
          v                                                   v
+----------------------+                           +----------------------+
| cp-00                |                           | dgx-spark            |
| 10.0.2.150           |                           | 10.0.2.160           |
| control plane        |                           | snapshot store       |
| netboot server       |                           +----------------------+
+----------+-----------+
           |
           | PXE / HTTP netboot
           |
   +-------+--------+--------+--------+
   |                |        |        |
   v                v        v        v
+--------+       +--------+ +--------+ +--------+
| wn-01  |       | wn-02  | | wn-03  | | wn-04  |
| .151   |       | .152   | | .153   | | .154   |
+--------+       +--------+ +--------+ +--------+

```

---

## 2. Hardware constraints you must know before starting

### Protectli FW2B
- **Intel Celeron J3060: 2 cores, 2 threads**, 1.6 GHz / 2.48 GHz turbo. (The quad-core J3160 is the FW4B — do not assume 4 cores.)
- **8 GB DDR3L maximum**, single SO-DIMM. Fit 8 GB in each.
- 1× mSATA + an internal SATA header. 2× Intel i211 1GbE. 2× HDMI. RJ45 serial console at **115200 8N1**.
- Ships with **AMI BIOS or coreboot**. **Both can netboot — you do not need to reflash.** Protectli's coreboot build is legacy-BIOS-only (SeaBIOS payload, no setup menu, `F11` for a boot menu) but **includes an iPXE ROM**, which is actually the better path here: iPXE runs straight from flash, so the TFTP chainload stage is skipped entirely. See Phase D for both variants.
- x86-64-v2 is satisfied (Airmont has SSE4.2, POPCNT, CX16), so Talos runs. No blocker.

### Intel NUC10FNH
- Comet Lake, single Intel i219-V NIC, M.2 NVMe + 2.5" SATA bay. Plenty for a control plane.

### ⚠️ This cluster is CPU-heterogeneous — it constrains §10

The NUC is Comet Lake (AVX, AVX2, BMI). The FW2Bs are Airmont — **SSE4.2 and nothing above it, no AVX at all.** That is close to the widest CPU feature gap two x86 machines can have.

It doesn't matter for plain Kubernetes. It matters enormously for Agent Substrate, because gVisor checkpoint images capture CPU feature state and **a snapshot taken on a machine with more features will not restore on one with fewer** ([google/gvisor#11486](https://github.com/google/gvisor/issues/11486)). A golden snapshot taken on the NUC will fail to restore on a FW2B, intermittently and with confusing errors.

The fix is to keep every Substrate WorkerPool pinned to a single homogeneous node set. §10 does this with `nodeSelector: hardware: fw2b`, which is why the `hardware: fw2b` node label in §4.3 is load-bearing and not cosmetic. **Never add the NUC to a WorkerPool, and re-baseline every ActorTemplate if you ever add a node of a different vintage.**

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
| Cluster subnet | everywhere | `10.0.2.0/24` |
| Router / gateway IP | firewall + reservations | `10.0.2.1` |
| NUC IP | everywhere | `10.0.2.150` |
| Worker IPs | nginx allowlist | `10.0.2.151` / `.152` / `.153` / `.154` |
| NUC NVMe device path | `patches/controlplane.yaml` | discovered in step **B3** |
| NUC network interface name | `dnsmasq.conf` | discovered in step **B7** |
| Talos version | asset job | `v1.13.6` |
| Image Factory schematic ID | asset job | `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba` (vanilla) |

### 3.1a Node inventory

| Hostname | Hardware | IP | Role | Boots from |
|---|---|---|---|---|
| `cp-00` | Intel NUC10FNH | `10.0.2.150` | control plane + netboot stack (+ §10 Substrate control plane, Valkey) | NVMe, installed |
| `wn-01` | Protectli FW2B | `10.0.2.151` | worker | network, every boot |
| `wn-02` | Protectli FW2B | `10.0.2.152` | worker | network, every boot |
| `wn-03` | Protectli FW2B | `10.0.2.153` | worker | network, every boot |
| `wn-04` | Protectli FW2B | `10.0.2.154` | worker | network, every boot |
| — | NVIDIA DGX Spark | `10.0.2.160` | §10 only: RustFS + image registry. **Not a cluster node.** | its own disk |

Gateway / router: `10.0.2.1`. Subnet: `10.0.2.0/24`.

### 3.2 Placeholders used in §4

Every file in §4 uses these literal values. If your network differs, change them once:

```bash
# run from the repo root created in step A2, after writing all files
grep -rl '10\.0\.2\.' . | xargs sed -i '' 's/10\.0\.2\./192.168.7./g'   # macOS
# grep -rl '10\.0\.2\.' . | xargs sed -i  's/10\.0\.2\./192.168.7./g'   # Linux
```

| Placeholder | Value in §4 | Also appears in |
|---|---|---|
| Cluster subnet | `10.0.2.0/24` | `dnsmasq.conf` |
| NUC | `10.0.2.150` | `dnsmasq.conf`, `boot.ipxe`, `talosconfig` endpoint |
| Workers | `10.0.2.151`–`10.0.2.154` | `nginx.conf` allowlist |
| NUC interface | `ENP_PLACEHOLDER` | `dnsmasq.conf` — replaced in step **C1** |
| NUC install disk | `/dev/nvme0n1` | `patches/controlplane.yaml` — verified in step **B3** |
| DGX Spark | `10.0.2.160` | §10 only — RustFS, registry |

### 3.3 Router preparation — do this before anything else

1. Create **DHCP reservations** for all four MACs at the IPs above.
2. Set the **hostname** in each reservation: `cp-00`, `wn-01`, `wn-02`, `wn-03`, `wn-04`. Talos picks up the DHCP-supplied hostname (option 12), which is why no hostname appears in any machine config below and why all four workers can share one config file.
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
│   ├── local-path-provisioner/
│   │   ├── kustomization.yaml
│   │   └── local-path-provisioner.yaml
│   ├── worker.yaml
│   ├── patch-hostname.yaml
│   └── patch-registry-mirror.yaml          # §10 only
├── k8s/
│   ├── 00-namespace.yaml
│   ├── 10-cm-dnsmasq.yaml
│   ├── 11-cm-nginx.yaml
│   ├── 12-cm-fetch-assets.yaml
│   ├── 20-job-fetch-assets.yaml
│   ├── 30-deploy-dnsmasq.yaml
│   └── 31-deploy-nginx.yaml
└── substrate/                           # §10 only
    ├── ate-demo-counter.yaml 
    ├── manifests/ate-install/homelab/
    │   └── kustomization.yaml        # copy into your substrate checkoutworkerpool-fw2b.yaml
    └── sandboxconfig-gvisor-homelab.yaml
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
  kubelet:
    extraConfig:
      featureGates:
        ClusterTrustBundle: true
        ClusterTrustBundleProjection: true
        PodCertificateRequest: true
cluster:
  allowSchedulingOnControlPlanes: true
  apiServer:
    extraArgs:
      feature-gates: "ClusterTrustBundle=true,ClusterTrustBundleProjection=true,PodCertificateRequest=true"
      runtime-config: "certificates.k8s.io/v1beta1=true"
  controllerManager:
    extraArgs:
      feature-gates: "ClusterTrustBundle=true,ClusterTrustBundleProjection=true,PodCertificateRequest=true"
  scheduler:
    extraArgs:
      feature-gates: "ClusterTrustBundle=true,ClusterTrustBundleProjection=true,PodCertificateRequest=true"
```

`allowSchedulingOnControlPlanes` is **required** — dnsmasq and nginx run on this node, and it removes the `node-role.kubernetes.io/control-plane:NoSchedule` taint.

**The feature gates are for Agent Substrate (§10).** Substrate's `podcertcontroller` depends on `ClusterTrustBundle` and `PodCertificateRequest`, and the install blocks forever waiting on ClusterTrustBundles that will never appear without them. They are **not on by default as of Kubernetes 1.36**, and the `certificates.k8s.io/v1beta1` runtime-config is what actually serves the API. If you are not doing §10, you can drop this whole block — it costs nothing to leave in, but it is not needed for a plain cluster.

> Gates are set on all four components, mirroring what Substrate's own kind config does (which is known to work). If a component crashloops with `unrecognized feature gate`, remove that gate from that component only — the ones that definitely matter are apiserver and kubelet.

---

### 4.3 `patches/worker.yaml`

```yaml
machine:
  nodeLabels:
    hardware: fw2b             # load-bearing — §10 pins WorkerPools to this
  kubelet:
    extraConfig:
      featureGates:            # §10 (Substrate) — see §4.2
        ClusterTrustBundle: true
        ClusterTrustBundleProjection: true
        PodCertificateRequest: true
      systemReserved:
        memory: 512Mi
      evictionHard:
        memory.available: 250Mi
  sysctls:
    vm.max_map_count: "262144"
    # --- §10 (Agent Substrate) below this line ---
    # gVisor requires unprivileged user namespace creation.
    user.max_user_namespaces: "11255"
    # gVisor sandbox pod-to-pod networking (actor interior IP 169.254.17.2).
    net.ipv4.conf.all.proxy_arp: "1"
```

**There is deliberately no `machine.install` section.** That is what stops Talos writing a bootloader to the mSATA and hijacking the netboot path on the next reboot.

Note `hardware: fw2b` has no domain prefix on purpose — the NodeRestriction admission plugin blocks a kubelet from self-assigning most `*.kubernetes.io` labels.

> ⚠️ `user.max_user_namespaces` **disables a KSPP hardening default** that Talos sets deliberately — Sidero's own gVisor extension README carries the same warning. Acceptable in a lab; be conscious you're doing it. Both Substrate sysctls are only needed on nodes that run sandboxes, i.e. the workers, not the NUC.
>
> `proxy_arp` is lifted from Substrate's own kind setup, where it's required for gVisor pod-to-pod networking. It may be unnecessary with Flannel on real nodes, but it is harmless — set it rather than debug it later.

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
    dhcp-range=10.0.2.0,proxy
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
    dhcp-boot=tag:ipxe,http://10.0.2.150:8080/boot.ipxe

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
        # Allowlist the four workers, log every request, deny everything else.
        location /config/ {
          alias /srv/config/;
          allow 10.0.2.151;
          allow 10.0.2.152;
          allow 10.0.2.153;
          allow 10.0.2.154;
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
              value: "http://10.0.2.150:8080"
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

**A5.** Add hostname configuration:

```bash
cat patches/patch-hostname.yaml >> controlplane.yaml
```

**A6.** Generate the machine configs with both patches applied in one shot:

```bash
talosctl gen config homelab https://10.0.2.150:6443 \
  --with-secrets secrets.yaml \
  --config-patch-control-plane @patches/controlplane.yaml \
  --config-patch-worker @patches/worker.yaml \
  --with-docs=false \
  --with-examples=false \
  --output-dir .
```

Produces `controlplane.yaml`, `worker.yaml`, `talosconfig`.

**A7.** Sanity-check the two things most likely to be wrong:

```bash
grep -A2 'install:' controlplane.yaml        # expect disk: /dev/nvme0n1
grep -c 'install:' worker.yaml               # expect 0 — no install section
grep 'allowSchedulingOnControlPlanes' controlplane.yaml   # expect true
```

**A8.** Download the ISO for the NUC (same version and schematic as the workers):

```bash
curl -LO https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.13.6/metal-amd64.iso
```

Write it to USB (`dd`, Rufus, balenaEtcher — whatever you like).

---

### Phase B — NUC: install Talos and bootstrap the cluster

**B1.** Boot the NUC from the USB stick. It comes up in **maintenance mode** and displays its DHCP address on the console dashboard. It should match your reservation (`10.0.2.150`).

**B2.** Point talosctl at it:

```bash
export TALOSCONFIG=$PWD/talosconfig
talosctl config endpoint 10.0.2.150
talosctl config node 10.0.2.150
```

**B3.** **Confirm the install disk** before applying anything:

```bash
talosctl -n 10.0.2.150 get disks --insecure
```

If the NVMe is not `/dev/nvme0n1`, fix `patches/controlplane.yaml` and re-run **A6**.

**B4.** Apply the control-plane config. The node installs to NVMe and reboots.

```bash
talosctl apply-config --insecure -n 10.0.2.150 -f controlplane.yaml
```

**B5.** Wait for it to come back (2–5 minutes), then bootstrap etcd. **Run this exactly once, ever.**

```bash
talosctl -n 10.0.2.150 bootstrap
```

**B6.** Fetch kubeconfig and confirm the node is up:

```bash
talosctl -n 10.0.2.150 kubeconfig ./kubeconfig
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide     # cp-00 Ready (may take a few minutes)
```

**B7.** **Discover the NUC's interface name** — you need it for dnsmasq:

```bash
talosctl -n 10.0.2.150 get links -o json | grep -i '"id"' | head -20
# or, more readable:
talosctl -n 10.0.2.150 get addresses
```

Look for the physical link carrying `10.0.2.150` — typically `enp0s31f6` on a NUC10. Record it.

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
curl -s http://10.0.2.150:8080/boot.ipxe

# kernel and initramfs are present and non-trivial in size
curl -sI http://10.0.2.150:8080/assets/vmlinuz-amd64      | head -3
curl -sI http://10.0.2.150:8080/assets/initramfs-amd64.xz | head -3

# config server correctly REFUSES your workstation (expect 403)
curl -s -o /dev/null -w '%{http_code}\n' http://10.0.2.150:8080/config/worker.yaml
```

A `403` on that last command means the allowlist works. A `200` means your workstation is inside the allowlist — check the IPs in `nginx.conf`.

**C8.** Leave a log tail running in a second terminal for Phase E:

```bash
kubectl -n netboot logs -f deploy/dnsmasq
```

---

### Phase D — FW2B firmware (physical access, all four units)

Attach a monitor to HDMI, or a serial console at **115200 8N1** over the RJ45 COM port. (Both work on either firmware — the coreboot port has serial on the front RJ45 confirmed working upstream.)

**First, find out which firmware you have.** Power on and watch the splash. coreboot shows a coreboot/SeaBIOS banner and responds to `F11`; AMI shows a setup prompt and responds to `Delete`.

Then follow **D-core** or **D-ami**, then D5–D7 which are common to both.

#### Path D-core — coreboot (no reflash needed)

Protectli's coreboot build ships **iPXE integrated as a network-boot ROM**. This is the *simpler* path: iPXE runs directly from flash, so stage 1 of §2's boot chain — TFTP-chainloading `undionly.kpxe` — never happens. iPXE DHCPs, dnsmasq sees the iPXE user-class / option 175 on the very first request, and hands back the HTTP script URL immediately.

**No change to `k8s/10-cm-dnsmasq.yaml` is required.** The `pxe-service` chainload lines simply never fire, and `dhcp-boot=tag:ipxe,...` does all the work. Leave the TFTP config in place — it costs nothing and you'll want it if you ever switch a unit to AMI.

**D-core-1.** Power on, hold `F11` for the boot menu. Confirm a network / iPXE entry is listed. If it is, the firmware can do everything you need.

**D-core-2.** Select the network entry and let it run **once**, manually, with `kubectl -n netboot logs -f deploy/dnsmasq` open. You should see a DHCPDISCOVER already tagged `ipxe`, and then an HTTP fetch of `boot.ipxe` in the nginx log — with no TFTP transfer in between. That confirms the whole path.

**D-core-3 — the one thing you must verify.** Reboot and **do not touch the keyboard.** The unit must reach iPXE and netboot unattended, or the netboot-every-boot design doesn't hold on this firmware.

With no bootloader on the mSATA (which is exactly what §4.3 arranges), SeaBIOS should fall through its boot order and land on the network ROM automatically. If it does, you are done — no reflash, ever.

If it instead drops to a prompt or hangs, pick one of these, cheapest first:

| Fallback | Cost | Notes |
|---|---|---|
| **iPXE on a USB stick** | ~5 min/unit, one cheap stick each | Write `ipxe.usb` from <https://boot.ipxe.org/> to a stick, leave it in permanently. SeaBIOS boots USB fine. **Use a rear USB 2.0 port** — upstream coreboot notes USB 3.0 devices are detected very late in SeaBIOS. |
| **Reflash coreboot with a `bootorder` file** | Build/flash effort | Puts the network BEV first persistently. `flashrom` works internally on these boards. |
| **Flash AMI BIOS** | Highest | Only if the above fail. Then follow D-ami. |

> One caveat that reads scarier than it is: Protectli's docs note that a URL **typed by hand** into the iPXE shell isn't saved across reboots. That's about interactive use. A URL delivered by DHCP (which is what your dnsmasq does) needs no persistence — it's re-supplied on every boot by design.

#### Path D-ami — AMI BIOS

**D-ami-1.** Power on, press `Delete` repeatedly to enter setup.

**D-ami-2.** **Advanced → CSM Configuration → Network → Legacy**. This is what makes the i211 ports appear as bootable devices. Without it there is no PXE option at all.

**D-ami-3.** `F4` → **Save & Exit** → Yes. The unit reboots.

**D-ami-4.** Re-enter setup. In **Boot**, set **network as the first boot device**, and **disable or remove the mSATA boot entry**. Belt-and-braces against a stray install taking over the boot path.

On this path the full two-stage chain runs: firmware PXE ROM → TFTP `undionly.kpxe` → iPXE → HTTP. The dnsmasq config in §4.5 handles it as written.

#### Common to both

**D5.** Internally, close the **`JPWR`** jumper so the unit powers on automatically when power is restored. Without it, a power cut means walking to the closet and pressing three buttons.

**D6.** **Cable only ONE NIC** — the port labeled `WAN`. Leave `LAN` unplugged. The `${mac}` substitution in `talos.config` resolves to *"the MAC address of the first network interface attaining link state up"*, which is a coin flip with both ports patched in.

**D7.** Repeat for all four units. Don't mix firmware across the four if you can avoid it — identical boot behaviour is worth more than it sounds when you're debugging at 1am.

---

### Phase E — Bring up the first worker

Do **one node only**, and watch it. If it works, the other two are copy-paste.

**E1.** Power on `wn-01`. On the dnsmasq log tail from C8 you should see, in order:

```
DHCPDISCOVER(enp0s31f6) aa:bb:cc:dd:ee:01
PXE(enp0s31f6) aa:bb:cc:dd:ee:01 proxy
...  undionly.kpxe
sent /var/lib/tftpboot/undionly.kpxe to 10.0.2.151
DHCPDISCOVER(enp0s31f6) aa:bb:cc:dd:ee:01          <- now from iPXE
... http://10.0.2.150:8080/boot.ipxe
```

**E2.** Then in the nginx log:

```bash
kubectl -n netboot logs -f deploy/nginx
```

Expect `GET /boot.ipxe`, `GET /assets/vmlinuz-amd64`, `GET /assets/initramfs-amd64.xz`, `GET /config/worker.yaml` — all `200`, all from `10.0.2.151`.

**E3.** Watch it join:

```bash
kubectl get nodes -w
```

`wn-01` should appear and reach `Ready` within a few minutes of the config fetch.

**E4.** Confirm what actually got provisioned on the mSATA:

```bash
talosctl -n 10.0.2.151 get volumestatus
talosctl -n 10.0.2.151 dmesg | tail -50
```

**E5.** **The critical test — reboot it and confirm it netboots again**, rather than booting from disk:

```bash
kubectl -n netboot logs -f deploy/nginx &     # keep watching
talosctl -n 10.0.2.151 reboot
```

A fresh `GET /config/worker.yaml` in the nginx log means netboot-every-boot is working. **No fetch means the node booted from disk** — see §7.1.

---

### Phase F — Remaining workers

**F1.** Power on `wn-02`, `wn-03` and `wn-04`, one at a time. No per-node configuration required — same `worker.yaml`, hostnames from DHCP reservations.

**F2.** Final state check:

```bash
kubectl get nodes -o wide
talosctl -n 10.0.2.150 health --wait-timeout 10m
```

Expect five nodes `Ready`: `cp-00` (control-plane) and `wn-01`/`02`/`03`/`04`.

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
talosctl -n 10.0.2.150 health --wait-timeout 10m

# workers have the expected label and no install section took effect
kubectl get nodes -l hardware=fw2b
talosctl -n 10.0.2.151,10.0.2.152,10.0.2.153,10.0.2.154 get volumestatus

# netboot stack running on the control plane only
kubectl -n netboot get pods -o wide

# config server still refuses non-workers
curl -s -o /dev/null -w '%{http_code}\n' http://10.0.2.150:8080/config/worker.yaml   # 403

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
| No PXE device in the FW2B boot menu (AMI) | CSM Network not set to Legacy | Redo step **D-ami-2** |
| No network entry in the `F11` menu (coreboot) | this coreboot build lacks the iPXE ROM | Use the USB-iPXE fallback in **D-core-3** |
| coreboot unit needs manual `F11` every boot | SeaBIOS isn't falling through to the network BEV | **D-core-3** fallback table |
| TFTP never appears in the dnsmasq log on coreboot | **expected** — firmware iPXE skips the chainload stage | Not a fault; see **D-core** |
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
2. Confirm the mSATA is not in the boot order (step **D-ami-4**; on coreboot there's nothing to set — SeaBIOS skips a disk with no bootloader).
3. Wipe and let it rebuild:
   ```bash
   talosctl -n 10.0.2.151 reset --graceful=false --reboot \
     --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL
   ```
4. If it keeps installing, accept the fallback: add `machine.install: {disk: /dev/sda}` to `patches/worker.yaml`, regenerate (**A6**), update the Secret (**C4**), and set the BIOS boot order to disk-first / network-fallback. You lose netboot-every-boot; you keep everything else.

### 7.2 Testing whether true zero-disk works

Curiosity satisfied cheaply: pull the mSATA out of `wn-04` and boot it. If it joins and reaches `Ready`, your Talos build tolerates a diskless worker. If it hangs in maintenance mode, you've confirmed the STATE requirement from §2 and the current design is the right one.

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
for n in 01 02 03 04; do
  kubectl drain "wn-${n}" --ignore-daemonsets --delete-emptydir-data || true
  talosctl -n "10.0.2.$((150 + 10#$n))" reboot
  kubectl wait --for=condition=Ready "node/wn-${n}" --timeout=10m
done
```

This is the payoff of netboot-every-boot: no per-node upgrade orchestration, no installer images.

### 8.2 Upgrading the control plane — normal Talos upgrade

```bash
talosctl -n 10.0.2.150 upgrade \
  --image factory.talos.dev/installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.13.7
```

The installer schematic **must match** the schematic used for the boot assets.

### 8.3 Backups — do this before you need it

```bash
talosctl -n 10.0.2.150 etcd snapshot etcd-$(date +%F).db
```

Single control plane means no quorum to save you. The three things that make a rebuild a 30-minute job instead of starting over:

1. `secrets.yaml`
2. `talosconfig`
3. a recent etcd snapshot

Schedule the snapshot. Store all three off the cluster.

### 8.4 Rebuilding a worker from scratch

```bash
talosctl -n 10.0.2.152 reset --graceful=false --reboot \
  --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL
```

It netboots, refetches `worker.yaml`, and rejoins. Nothing to reinstall.

### 8.5 Hardening beyond the allowlist

The nginx allowlist is a speed bump, not a boundary. In rough order of cost:

1. **VLAN the cluster.** Node ports must be **untagged access ports** — the i211 option ROM has no 802.1Q awareness and stage-1 iPXE DHCPs untagged, so a tagged trunk means DHCP silently finds nothing. Firewall LAN→cluster down to tcp/6443 and tcp/50000; explicitly deny tcp/8080, udp/69, udp/67.
2. **Bind nginx to the cluster VLAN address** (`listen 10.0.20.10:8080`) once the NUC has more than one address. Set `net.ipv4.ip_nonlocal_bind: "1"` in the control plane's `machine.sysctls`, or nginx will crashloop when it starts before the address is up.
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

If you take on §10, add these:

7. **CPU-heterogeneous checkpoint/restore.** A gVisor snapshot from the NUC will not restore on a FW2B. Mitigated only by the `nodeSelector` in §10.10 — there is no runtime guard. See §2.
8. **Substrate is pre-release.** `v0.0.0`, no published images, APIs expected to change, GKE-shaped install path. Every upgrade is a rebuild from source.
9. **Snapshots are the sole copy of actor state**, on a beta single-node object store on one box. §10.14.
10. **1GbE bounds activation latency.** RAM images over the wire; seconds, not milliseconds. §10.13.

---

## 10. Agent Substrate + RustFS

Everything in this section is optional and independent of §1–§9. Do it only after §6 passes.

> **Maturity warning, stated once.** Agent Substrate self-describes as "VERY early development... APIs are almost guaranteed to change." Its only release is `v0.0.0 - initial commit`. There are **no published container images** — every component is a `ko://` reference built from source. The non-kind install path assumes GKE, GCS, and Memorystore; you are porting it to bare metal. RustFS is at `1.0.0-beta`. Treat this as an experiment you can rebuild, not infrastructure you depend on.

### 10.1 Placement

| Component | Where | Why |
|---|---|---|
| `ate-api-server`, `ate-controller`, `atenet-router`, `atenet-dns` | **NUC** (control plane) | Control-plane latency, and the FW2Bs have no spare cores |
| `valkey-cluster` (StatefulSet) | **NUC** | Actor registry; needs a real disk. **Substrate deploys this itself** — you don't install Valkey separately, you pin the StatefulSet it creates |
| `podcertificate-controller` | **NUC** | Signs pod certs for the mTLS mesh |
| `atelet` (DaemonSet) | **all nodes** | Node agent; does snapshot I/O. Leave it unpinned |
| Worker pods / actors | **FW2Bs only** | Enforced by `nodeSelector: hardware: fw2b` — see §2 |
| **RustFS** | **DGX Spark**, outside the cluster | 4 TB NVMe, and keeps snapshot state off disposable workers |

The stock install deploys RustFS *in-cluster* as part of the kind overlay. §10.5 replaces that with the Spark.

### 10.2 Prerequisites

| Requirement | Where it's handled |
|---|---|
| Kubernetes ≥ 1.36 | §10.3 — Substrate supports latest stable and one minor back |
| `ClusterTrustBundle`, `ClusterTrustBundleProjection`, `PodCertificateRequest` gates + `certificates.k8s.io/v1beta1` | §4.2 (control plane) and §4.3 (kubelet) |
| `user.max_user_namespaces`, `net.ipv4.conf.all.proxy_arp` | §4.3 (workers) |
| A container registry the cluster can pull from | §10.4 |
| RustFS reachable over S3 | §10.5 |
| Go, `ko`, `kustomize`, `jq`, `docker` on your workstation | §10.6 |

**You do not need the `siderolabs/gvisor` system extension.** Substrate fetches its own `runsc` binary via `SandboxConfig` and runs it inside the worker pod. Your schematic ID and netboot assets from §4.1 are unchanged — nothing in §3–§7 needs to be redone.

### 10.3 Container registry on the Spark

There are no published Substrate images, so you need a registry the cluster can pull from. Simplest is one on the Spark alongside RustFS.

```bash
# on the DGX Spark (10.0.2.160)
sudo mkdir -p /srv/registry
docker run -d --name registry --restart unless-stopped \
  -p 5000:5000 -v /srv/registry:/var/lib/registry \
  registry:3
```

Talos must be told this registry is plain HTTP. This lives in **`patches/registry-mirror.yaml`**:

```yaml
---
apiVersion: v1alpha1
kind: RegistryMirrorConfig
mirrors:
  10.0.2.160:5000:
    endpoints:
      - url: http://10.0.2.160:5000
```

Append it to both generated configs after running `talosctl gen config` — it is a standalone config document, so a plain concatenation is enough:

```bash
cat patches/registry-mirror.yaml >> controlplane.yaml
cat patches/registry-mirror.yaml >> worker.yaml
```

> `RegistryMirrorConfig` is the current form; the older `machine.registries.mirrors` still works but is deprecated as of Talos 1.12. If you'd rather avoid an insecure registry entirely, push to `ghcr.io` instead and skip this — then `KO_DOCKER_REPO=ghcr.io/<you>` in §10.6 and ensure the images are public or add an imagePullSecret.

### 10.4 Update Talos Configuration

Talos v1.13.6 ships Kubernetes 1.35, which is one minor behind. Upgrade to Kubernetes 1.36 before installing:

```bash
talosctl --nodes 10.0.2.150 upgrade-k8s --to 1.36.1
kubectl version
kubectl get nodes -o wide     # all four still Ready
```

Then apply the §4.2/§4.3 patches if you haven't already:

```bash
# regenerate with the new patches
talosctl gen config homelab https://10.0.2.150:6443 \
  --with-secrets secrets.yaml \
  --config-patch-control-plane @patches/controlplane.yaml \
  --config-patch-worker @patches/worker.yaml \
  --with-docs=false --with-examples=false --output-dir . --force

talosctl -n 10.0.2.150 apply-config -f controlplane.yaml

# workers pick the new config up on next boot — refresh the served copy first
kubectl -n netboot create secret generic machine-config \
  --from-file=worker.yaml=./worker.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

for ip in 10.0.2.151 10.0.2.152 10.0.2.153 10.0.2.154; do talosctl -n $ip reboot; sleep 120; done
```

Verify the gates actually took:

```bash
kubectl api-resources | grep -i clustertrustbundle    # must return rows
kubectl get --raw /apis/certificates.k8s.io/v1beta1 | jq -r '.resources[].name'
talosctl -n 10.0.2.151 read /proc/sys/user/max_user_namespaces   # 11255
```

If `clustertrustbundles` is missing, stop. The Substrate install will hang forever at "Waiting for podcertificate ClusterTrustBundles to be ready".

### 10.5 RustFS on the DGX Spark

The Spark is arm64 (GB10, 20-core Arm) running DGX OS — Ubuntu 24.04. RustFS publishes arm64 images, so this is a straight `docker run`.

```bash
# on the DGX Spark
sudo mkdir -p /srv/rustfs/logs
sudo chown -R 10001:10001 /srv/rustfs      # container runs as UID/GID 10001

docker volume create rustfs-data

docker run -d \
  --name rustfs \
  --restart unless-stopped  \
  -p 9000:9000 \
  -p 9001:9001 \
  -v rustfs-data:/data \
  -v /srv/rustfs/logs:/logs \
  -e RUSTFS_ACCESS_KEY="substrate" \
  -e RUSTFS_SECRET_KEY_FILE=./rustfs_secret_key \ # pick up the secret from a local file
  -e RUSTFS_ADDRESS=":9000" \
  -e RUSTFS_CONSOLE_ADDRESS=":9001" \
  -e RUSTFS_CONSOLE_ENABLE=true \
  -e RUSTFS_OBS_LOGGER_LEVEL=error \
  rustfs/rustfs:1.0.0-beta.3 \
  /data
```

> Pin the tag. Substrate's own manifest pins `rustfs/rustfs:1.0.0-beta.3@sha256:378642b0...` — matching their tested version is the safer choice on a beta storage engine. And change the credentials: the upstream default is `rustfsadmin`/`rustfsadmin`, which is fine inside a kind cluster and not fine on your LAN.

Create the bucket:

```bash
# from your workstation, with awscli installed
export AWS_ACCESS_KEY_ID=substrate
export AWS_SECRET_ACCESS_KEY='<a real password>'
export AWS_REGION=us-east-1
aws --endpoint-url http://10.0.2.160:9000 s3api create-bucket --bucket ate-snapshots
aws --endpoint-url http://10.0.2.160:9000 s3 ls
```

Store the credentials as a Secret rather than inlining them the way upstream does (their manifest carries a `TODO: use a secret / identity management`):

```bash
kubectl create namespace ate-system --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ate-system create secret generic rustfs-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=substrate \
  --from-literal=AWS_SECRET_ACCESS_KEY='<a real password>'
```

### 10.6 Build and push the Substrate images

```bash
git clone https://github.com/agent-substrate/substrate.git
cd substrate

export KO_DOCKER_REPO=10.0.2.160:5000
export KO_DEFAULTPLATFORMS=linux/amd64      # all four cluster nodes are amd64
export NO_DEV_ENV=true
export BUCKET_NAME=ate-snapshots
```

`KO_DEFAULTPLATFORMS=linux/amd64` matters: the Spark is arm64, so `ko` would otherwise build for the wrong architecture if it inferred from the host. Build on an amd64 workstation, or set this explicitly.

### 10.7 The `homelab` kustomize overlay

Upstream ships two overlays: `manifests/ate-install` (GKE) and `manifests/ate-install/kind`. Neither fits — the GKE one wants GCS, the kind one deploys RustFS in-cluster. Create a third in your checkout:

**`manifests/ate-install/homelab/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../ate-api-server.yaml
  - ../ate-controller.yaml
  - ../atelet.yaml
  - ../atenet-dns.yaml
  - ../atenet-router.yaml
  - ../valkey.yaml
  - ../pod-certificate-controller.yaml
  # NOTE: no rustfs.yaml — RustFS lives on the Spark (§10.5)
  # NOTE: no otel-collector / prometheus — add later if you want them

patches:
  # ---- atelet: point snapshot storage at RustFS on the Spark ----
  - patch: |-
      apiVersion: apps/v1
      kind: DaemonSet
      metadata:
        name: atelet
        namespace: ate-system
      spec:
        template:
          spec:
            containers:
            - name: atelet
              args:
              - --gcp-auth-for-image-pulls=false
              - --grpc-server-cred-bundle=/run/podidentity.podcert.ate.dev/credential-bundle.pem
              - --client-ca-certs=/run/podidentity.podcert.ate.dev/trust-bundle.pem
              env:
              - name: ATE_STORAGE_BACKEND
                value: s3
              - name: AWS_REGION
                value: us-east-1
              - name: AWS_ENDPOINT_URL
                value: http://10.0.2.160:9000
              - name: AWS_S3_USE_PATH_STYLE
                value: "true"
              - name: AWS_ACCESS_KEY_ID
                valueFrom:
                  secretKeyRef:
                    name: rustfs-credentials
                    key: AWS_ACCESS_KEY_ID
              - name: AWS_SECRET_ACCESS_KEY
                valueFrom:
                  secretKeyRef:
                    name: rustfs-credentials
                    key: AWS_SECRET_ACCESS_KEY
              - name: OTEL_EXPORTER_OTLP_ENDPOINT
                value: ""

  # ---- Valkey pinned to the NUC ----
  - patch: |-
      apiVersion: apps/v1
      kind: StatefulSet
      metadata:
        name: valkey-cluster
        namespace: ate-system
      spec:
        template:
          spec:
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""

  # ---- control-plane components pinned to the NUC ----
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: ate-api-server
        namespace: ate-system
      spec:
        template:
          spec:
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: ate-controller
        namespace: ate-system
      spec:
        template:
          spec:
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: atenet-router
        namespace: ate-system
      spec:
        template:
          spec:
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: dns
        namespace: ate-system
      spec:
        template:
          spec:
            nodeSelector:
              node-role.kubernetes.io/control-plane: ""
```

> ⚠️ **The `gs://` scheme is a red herring.** Snapshot locations in `ActorTemplate.snapshotsConfig.location` are written as `gs://<bucket>/<path>/` **even when the backend is S3** — upstream's own kind demos do exactly this while writing to RustFS. The backend is chosen by `ATE_STORAGE_BACKEND` on atelet, not by the URL scheme. Do not "fix" it to `s3://`.

### 10.8 SandboxConfig — the `runsc` binary

`deploy_ate_system` applies a cluster default `SandboxConfig` named `gvisor-default`, whose assets point at gVisor nightly builds on Google Cloud Storage. Check what scheme it uses:

```bash
kubectl get sandboxconfig gvisor-default -o yaml
```

If the `url` is `gs://...` and your cluster has no GCP credentials, override it with the public HTTPS equivalent (**`substrate/sandboxconfig-gvisor-homelab.yaml`**):

```yaml
apiVersion: ate.dev/v1alpha1
kind: SandboxConfig
metadata:
  name: gvisor-homelab
spec:
  sandboxClass: gvisor
  default: true
  assets:
    amd64:
      runsc:
        url: "https://storage.googleapis.com/gvisor/releases/nightly/2026-05-19/x86_64/runsc"
        sha256: "a397be1abc2420d26bce6c70e6e2ff96c73aaaab929756c56f5e2089ea842b63"
```

Set `default: false` on `gvisor-default` first — at most one default is allowed per `sandboxClass`, and a `ValidatingAdmissionPolicy` enforces it. Verify the sha256 against whatever release you actually point at; the digest above is the one in upstream's example and is version-specific.

### 10.9 Install

```bash
cd substrate
export KUBECONFIG=/path/to/kubeconfig

# 1. CRDs and the SandboxConfig validation policy
./hack/run-tool.sh ko apply -f manifests/ate-install/generated
kubectl apply -f manifests/ate-install/sandboxconfig-validation.yaml
kubectl apply -f manifests/ate-install/sandboxconfig-gvisor.yaml

# 2. Namespace — confirm it carries PSA privileged labels; add them if not
kubectl apply -f manifests/ate-install/ate-system-namespace.yaml
kubectl get ns ate-system --show-labels
kubectl label ns ate-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite

# 3. RustFS credentials (§10.5) must exist before atelet starts
kubectl -n ate-system get secret rustfs-credentials

# 4. CAs, JWT pools, apiserver env — reuse upstream's helpers
./hack/install-ate.sh --create-podcertificate-controller-cas
./hack/install-ate.sh --create-jwt-authority-pool-secret
./hack/install-ate.sh --create-session-id-ca-pool-secret

# 5. podcertificate-controller, then wait for the trust bundles
./hack/run-tool.sh ko apply -f manifests/ate-install/pod-certificate-controller.yaml
kubectl rollout status deployment/podcertificate-controller -n podcertificate-controller-system --timeout=120s
kubectl get clustertrustbundles

# 6. Valkey CA certs (depends on step 5 having produced the CA pools)
./hack/install-ate.sh --create-valkey-ca-certs-secret
./hack/install-ate.sh --create-api-server-env-vars

# 7. The system itself, through the homelab overlay
talosctl --nodes 10.0.2.150 patch mc --patch @install/patches/local-path-provisioner/local-path-provisioner.yaml
kubectl kustomize manifests/ate-install/homelab --load-restrictor LoadRestrictionsNone \
  | ./hack/run-tool.sh ko resolve -f - \
  | kubectl apply -f -

# 8. Wait
kubectl rollout status deployment/ate-api-server  -n ate-system --timeout=300s
kubectl rollout status deployment/ate-controller  -n ate-system --timeout=300s
kubectl rollout status deployment/atenet-router   -n ate-system --timeout=300s
kubectl rollout status statefulset/valkey-cluster -n ate-system --timeout=300s
kubectl rollout status daemonset/atelet           -n ate-system --timeout=300s
```

Step 5 is the one that hangs if §10.3 didn't take. If `kubectl get clustertrustbundles` returns `the server doesn't have a resource type`, go back and fix the feature gates.

### 10.10 WorkerPool — FW2B only

This is the piece that keeps §2's CPU problem from biting you. File: **`substrate/workerpool-fw2b.yaml`**.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ate-demo
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: ate.dev/v1alpha1
kind: WorkerPool
metadata:
  name: fw2b-pool
  namespace: ate-demo
  labels:
    workload: homelab
spec:
  # 4 nodes × 2 warm pods. Each worker pod holds a gVisor sandbox in RAM.
  replicas: 8
  ateomImage: ko://github.com/agent-substrate/substrate/cmd/ateom-gvisor
  sandboxClass: gvisor
  template:
    # THE important line. Never let the NUC into this pool — see §2.
    nodeSelector:
      hardware: fw2b
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: "1"
        memory: 1500Mi
```

Sizing rationale for an 8 GB / 2-core FW2B: Talos plus kubelet takes ~1–1.5 GB, and `systemReserved`/`evictionHard` from §4.3 hold back another ~750 MB. That leaves roughly 5.5–6 GB per node. Two worker pods at a 1.5 GB limit is ~3 GB, which leaves headroom for atelet, the CNI, and actor filesystem cache. Across four FW2Bs that's 8 warm pods. Raise `replicas` only after watching real memory under load.

### 10.11 ActorTemplate

File: **`substrate/ate-demo-counter.yaml`**.

```yaml
apiVersion: ate.dev/v1alpha1
kind: ActorTemplate
metadata:
  name: counter
  namespace: ate-demo
spec:
  sandboxClass: gvisor
  pauseImage: "registry.k8s.io/pause:3.10.2@sha256:f548e0e8e3dc1896ca956272154dde3314e8cc4fde0a57577ee9fa1c63f5baf4"
  containers:
  - name: counter
    image: ko://github.com/agent-substrate/substrate/demos/counter
    command:
    - /ko-app/counter
    readyz:
      httpGet:
        path: /readyz
        port: 80
    volumeMounts:
    - name: data
      mountPath: /home/counter
  workerSelector:
    matchLabels:
      workload: homelab          # must match the WorkerPool's labels
  snapshotsConfig:
    onPause: Full
    onCommit: Data
    location: gs://ate-snapshots/ate-demo-counter/     # gs:// — see §10.7
  volumes:
  - name: data
    durableDir: {}
```

Apply it through `ko` so the `ko://` reference resolves:

```bash
./hack/run-tool.sh ko apply -f <path-to>/substrate/ate-demo-counter.yaml
kubectl -n ate-demo get actortemplate counter -o jsonpath='{.status.phase}'   # want: Ready
```

The golden snapshot is taken on whichever worker the golden pod lands on — which, thanks to the `nodeSelector`, is always a FW2B. That's the invariant that makes restores work.

### 10.12 Verify end to end

```bash
go install ./cmd/kubectl-ate

kubectl ate create actor my-counter-1 --template ate-demo/counter
kubectl ate get actors -A

# snapshot actually landed on the Spark
aws --endpoint-url http://10.0.2.160:9000 s3 ls s3://ate-snapshots/ate-demo-counter/ --recursive

# exercise it
kubectl port-forward -n ate-system svc/atenet-router 8000:80 &
curl -X POST -H "Host: my-counter-1.actors.resources.substrate.ate.dev" -i http://localhost:8000/

# suspend / resume round trip — this is the real test
kubectl ate suspend actor my-counter-1 -a ate-demo
kubectl ate resume  actor my-counter-1 -a ate-demo
curl -X POST -H "Host: my-counter-1.actors.resources.substrate.ate.dev" -i http://localhost:8000/
```

The counter must keep its value across suspend/resume. If it does, RAM snapshotting to the Spark works. Then suspend, cordon the node it was on, and resume — it should come back on a *different* FW2B. That proves cross-node restore, which is the whole point.

### 10.13 Expect this to be slow, and why

Snapshots are **RAM images** moving over 1GbE at roughly 110 MB/s. A 512 MB actor is ~5 seconds each way. Upstream's "sub-second activation" assumes cloud networking and local SSD; you will not see it. Moving RustFS onto the NUC wouldn't help either — the FW2B's single 1GbE NIC is the bottleneck regardless of where the store sits.

**The one real mitigation you already own:** each FW2B has a second, unused i211. PXE happens on `eth0` before the machine config applies, so bringing up the second NIC afterwards costs you nothing in §5 and doesn't affect `${mac}` determinism. Add to `patches/worker.yaml`:

```yaml
---
apiVersion: v1alpha1
kind: DHCPv4Config
name: <second interface name>     # confirm with: talosctl -n <ip> get links
```

Then give the Spark an address on that segment and point `AWS_ENDPOINT_URL` at it. Worth doing only after you've measured the default path and confirmed the network is actually the limit.

### 10.14 What to watch

1. **Never add the NUC to a WorkerPool.** §2. This is the failure that will look like a Substrate bug and isn't.
2. **`gs://` in `snapshotsConfig.location` is correct with an S3 backend.** §10.7.
3. **Snapshots are the only copy of actor state.** RustFS is beta, single-node, on one box. Back `/srv/rustfs/data` up, or accept that a Spark disk failure loses every actor.
4. **Talos upgrades reset worker sysctls** only if you forget to re-serve `worker.yaml`. The §8.1 upgrade flow refreshes assets but not the config Secret — re-run the §10.3 secret refresh whenever `patches/worker.yaml` changes.
5. **`user.max_user_namespaces` weakens KSPP hardening** on the workers. §4.3.
6. **Pin every image by digest in ActorTemplates.** Changing an image invalidates snapshots, and upstream requires digest pinning for exactly this reason.
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
- [Agent Substrate](https://github.com/agent-substrate/substrate)
- [Substrate API guide (WorkerPool / ActorTemplate / SandboxConfig)](https://github.com/agent-substrate/substrate/blob/main/docs/api-guide.md)
- [Substrate kind cluster config — required feature gates](https://github.com/agent-substrate/substrate/blob/main/hack/create-kind-cluster.sh)
- [Substrate atelet S3 wiring (kind overlay)](https://github.com/agent-substrate/substrate/blob/main/manifests/ate-install/kind/atelet/kustomization.yaml)
- [Substrate RustFS manifest](https://github.com/agent-substrate/substrate/blob/main/manifests/ate-install/kind/rustfs.yaml)
- [gVisor checkpoint/restore](https://gvisor.dev/docs/user_guide/checkpoint_restore/)
- [gvisor#11486 — checkpoint/restore across differing CPU features](https://github.com/google/gvisor/issues/11486)
- [Talos gVisor extension (user namespace sysctl)](https://github.com/siderolabs/extensions/tree/main/container-runtime/gvisor)
- [RustFS](https://github.com/rustfs/rustfs)
