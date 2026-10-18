# talos-homelab — current status

Review of [danaschwanden/talos-homelab](https://github.com/danaschwanden/talos-homelab) (last commit 2026-08-12, "Fix worker pool config") against [agent-substrate/substrate](https://github.com/agent-substrate/substrate) `main` as of 2026-10-18.

**Summary:** The Talos and netboot part (§1–§9) is solid. The Agent Substrate section (§10) no longer matches upstream and would not install as written. The repo also has some internal mistakes.

## What the repo is

A runbook (`README.md`) plus the files under `install/` for:

- **Control plane:** an Intel NUC10FNH (`cp-00`, 10.0.2.150) running Talos v1.13.6. It also runs the netboot stack: dnsmasq answering PXE requests alongside the router's DHCP, nginx serving the boot assets, and a Job that generates `boot.ipxe` from Image Factory.
- **Workers:** 4× Protectli FW2B (`wn-01`…`wn-04`, .151–.154) that netboot on every boot. Their mSATA holds only Talos's STATE and EPHEMERAL partitions, with no install.
- **§10:** Agent Substrate with gVisor, WorkerPool pinned to the FW2Bs. Snapshots go to RustFS on the DGX Spark (10.0.2.160, not a cluster node).

The design reasoning is good:

- CPU-heterogeneous gVisor snapshots won't restore across machines, which is why the `hardware: fw2b` label is load-bearing.
- There is deliberately no `machine.install` on workers.
- The PSA namespace labels are set.
- §10.13 is honest about 1GbE limiting resume speed.

## About Agent Substrate (upstream)

- Google-led (with Solo.io) Kubernetes add-on. It multiplexes many mostly-idle, untrusted, stateful "actors" onto a small pool of warm sandboxed worker pods. Idle actors are snapshotted (RAM + filesystem) to object storage and restored on demand.
- Claimed performance: resume under 400ms, more than 1500 activations per second, 10–30x oversubscription.
- Components:
  - `ateapi`: control plane, backed by PostgreSQL.
  - `atelet`: node DaemonSet that does snapshot and restore.
  - `ateworker-gvisor` / `ateworker-microvm`: run the actor inside the worker pod.
  - `atenet`: Envoy router plus egress gateway.
  - `atecontroller`, `ate-idp-server`, `podcertcontroller`.
- Security model:
  - Actors are always sandboxed (gVisor or Cloud Hypervisor microVM).
  - Each actor gets a SPIFFE identity.
  - Networking is default-deny.
  - Credentials are injected by the egress gateway, so they never enter the sandbox.
- Cluster requirements:
  - Kubernetes 1.36+ with `PodCertificateRequest` + `ClusterTrustBundle` beta APIs, or 1.37+ where they're on by default.
  - PostgreSQL.
  - S3-compatible object store.
  - `/dev/kvm` for microVM mode.
- Maturity: the architecture doc still says "much of this architecture is aspirational". Tagged releases now exist up to **v0.5.0**.

## §10 has drifted from upstream

| Runbook says | Upstream today |
|---|---|
| Valkey StatefulSet, `valkey.yaml`, `--create-valkey-ca-certs-secret` | Valkey is gone (no references at all). The store is **PostgreSQL** (`manifests/ate-install/postgres/`). |
| `atenet-dns.yaml`, `dns` Deployment | Gone. The new components are `atenet-egress`, `ate-idp-server` and `ate-system-networkpolicies.yaml`. |
| WorkerPool `ateomImage: …/cmd/ateom-gvisor`, `sandboxClass: gvisor` | `workerImage: ko://go.ate.dev/substrate/cmd/ateworker-gvisor`, plus `sandboxClasses: [{name: gvisor}]`. The module path is now `go.ate.dev/substrate`. |
| `ActorTemplate` applied as a Kubernetes CRD into namespace `ate-demo` | ActorTemplates **are not CRDs any more**. They live in an *atespace* and are created with `kubectl ate create actor-template -f` in protojson form (see `demos/counter/counter-template.yaml.tmpl`). |
| Template fields `readyz`, `snapshotsConfig.onPause/onCommit/location` | `wakeupProbe`, `snapshotConfig.preferredFidelity: SNAPSHOT_FIDELITY_MEMORY`, `snapshotConfig.storageLocation`, plus a per-actor `resources` block |
| S3 `AWS_*` env set on the `atelet` container | The S3 env now goes on atelet's **`objectstore-plugin` initContainer** (`manifests/ate-install/kind/atelet/kustomization.yaml`) |
| `Host: <actor>.actors.resources.substrate.ate.dev` header; `kubectl ate create actor … --template ate-demo/counter` | `ate-target-actor: <atespace>/<actor>` header; `kubectl ate create actor <name> -a <atespace> --template counter` |
| No egress setup | `install-ate.sh` now requires `--credential-provider` (e.g. `'{"name":"k8s.io"}'`, or `'{"enabled":false}'`) |
| "`v0.0.0`, no published images" | Tags up to **v0.5.0** exist. Check whether images are published, which might let you drop the ko build and the registry on the Spark. |

**Recommendation:** rebuild the homelab overlay from upstream's `manifests/ate-install/kind` overlay rather than patching the old file list:

- swap the in-cluster rustfs for the Spark endpoint;
- pin Postgres and the control-plane deployments to the NUC;
- keep the WorkerPool `nodeSelector: hardware: fw2b`.

## Mistakes inside the repo

1. **`patches/controlplane.yaml` and `patches/worker.yaml` aren't in the repo.** They exist only as README snippets, yet they carry the Substrate feature gates, the sysctls and the `hardware: fw2b` label.
2. **Paths don't match.** The README uses `patches/…` and `k8s/…`, but the files are under `install/`. `install/README.md` points to `talos-netboot-cluster-design.md`, which doesn't exist, and calls the NUC `cp-01` (everywhere else it's `cp-00`).
3. **Step A5 does nothing.** It appends `patch-hostname.yaml` to `controlplane.yaml` before A6, and A6's `gen config` then refuses to run or overwrites the file. Pass it as `--config-patch-control-plane @install/patches/patch-hostname.yaml` instead.
4. **The schematic doesn't match.** `install/k8s/20-job-fetch-assets.yaml` uses `2d61dd07…` (with intel-ucode), but the NUC ISO (A8) and the §8.2 upgrade image use the vanilla `37656798…`. §8.2 itself says these must match.
5. **The registry mirror patch disagrees with the README.** `install/patches/patch-registry-mirror.yaml` mirrors `'*'` to `http://10.0.1.50:5000`, which is outside the 10.0.2.0/24 subnet. The README uses `10.0.2.160:5000` with a different schema.
6. **The RustFS `docker run` (§10.5) breaks.**
   - The `\ # pick up the secret…` comment ends the command, so every flag after it is silently dropped.
   - `RUSTFS_SECRET_KEY_FILE=./rustfs_secret_key` points to a file that is never mounted into the container.
   - §10.14 says to back up `/srv/rustfs/data`, but the data actually lives in the `rustfs-data` Docker volume.
7. **Smaller things:**
   - The dnsmasq config in README §4.5 is out of date; the repo version (`eno1`, `bind-dynamic`, finer iPXE option-175 tagging) is the better one.
   - Phase E says "the other two" workers, but there are three.
   - The local-path-provisioner kustomization (`install/patches/local-path-provisioner/`) is never applied anywhere in the runbook. Only the Talos `UserVolumeConfig` is patched in (§10.9 step 7).

## Next steps

- [ ] Fix internal mistakes 1–7.
- [ ] Rewrite §10 and `install/substrate/` against current upstream (Postgres, new WorkerPool shape, ActorTemplate via `kubectl ate`, objectstore-plugin S3 env, credential provider).
- [ ] Check whether v0.5.0 publishes container images.
