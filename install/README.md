# talos-homelab

Config extracted from `talos-netboot-cluster-design.md`. Filenames and paths match
the section numbers in that document — read it first; this tree is not self-explanatory.

    cp-01   Intel NUC10FNH   10.0.2.150   control plane + netboot stack
    wn-01   Protectli FW2B   10.0.2.151   worker (netboots every boot)
    wn-02   Protectli FW2B   10.0.2.152   worker
    wn-03   Protectli FW2B   10.0.2.153   worker
    wn-04   Protectli FW2B   10.0.2.154   worker
    --      NVIDIA DGX Spark 10.0.2.160   PostgreSQL + RustFS + registry (NOT a cluster node, §10)

    gateway 10.0.2.1     subnet 10.0.2.0/24

## Layout

| Path | Doc section | Notes |
|---|---|---|
| `schematic.yaml` | §4.1 | Image Factory schematic. Optional — skip for the vanilla schematic ID. |
| `patches/controlplane.yaml` | §4.2 | Verify `install.disk` at step B3 before use. |
| `patches/worker.yaml` | §4.3 | Deliberately has **no** `machine.install` — that's what keeps netboot working. |
| `patches/controlplane-substrate-label.yaml` | §10 | §10 only. Patch into `controlplane.yaml`. |
| `patches/trusted-roots.yaml` | §10 | §10 only. Generated on the Spark; append to both generated configs. |
| `k8s/*.yaml` | §4.4–§4.10 | Apply `00-namespace.yaml` first and on its own. |
| `substrate/*` | §10 | §10 only. Self-contained runbook: [`substrate/README.md`](substrate/README.md). |

## Before you apply anything

1. `k8s/10-cm-dnsmasq.yaml` contains `ENP_PLACEHOLDER` — replace with the NUC's real
   interface name, discovered at step **B7**. Nothing works until you do.
2. `patches/controlplane.yaml` assumes `/dev/nvme0n1`. Confirm at step **B3**.
3. The four worker IPs are hardcoded in the `nginx.conf` allowlist inside
   `k8s/11-cm-nginx.yaml`. If your addressing differs, change them there too.

## Order

    A: talosctl gen secrets / gen config          (§5 Phase A)
    B: install + bootstrap cp-01                  (§5 Phase B)
    C: kubectl apply k8s/ + create machine-config (§5 Phase C)
    D: FW2B firmware                              (§5 Phase D)
    E: first worker, watched                      (§5 Phase E)
    F: remaining workers                          (§5 Phase F)

Never commit the files listed in `.gitignore` — `worker.yaml` in particular carries
`machine.token` and `cluster.token`.
