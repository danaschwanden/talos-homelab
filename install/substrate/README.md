# Agent Substrate on talos-homelab

Runbook for installing [Agent Substrate](https://github.com/agent-substrate/substrate) on the cluster built by the [main runbook](../../README.md). Do this only after the main runbook's §6 checks pass.

Substrate keeps a large number of mostly idle, stateful **Actors** on a small set of warm **Workers**. It snapshots idle Actors to object storage and resumes them on demand. Terms follow [GLOSSARY.md](../../GLOSSARY.md). Why the state lives on the Spark: [ADR 0001](../../docs/adr/0001-substrate-state-on-the-spark.md).

> **Upstream tracking.** This tracks upstream `main`, which changes often.
> **Last verified against `agent-substrate/substrate@d2b97509984c4dc2df75f128a05f221a7cf98107` (2026-10-18).**
> When something breaks, start with
> `git log d2b9750..main -- manifests/ate-install/ demos/counter/ cmd/ate-setup/ pkg/api/ docs/postgres.md`,
> fix the files here, and bump the SHA above.

## Shape

```
          cp-00 (NUC)                          wn-01 … wn-04 (FW2B)
  ┌──────────────────────────────┐      ┌──────────────────────────────┐
  │ ate-api-server ate-controller│      │ atelet + objectstore-plugin  │
  │ atenet-router  atenet-egress │      │ 1 Worker (ateworker-gvisor)  │
  │ ate-idp-server podcert-ctrl  │      │   3Gi, 0.5–1.5 CPU           │
  │ k8s-credential-provider      │      └──────────────┬───────────────┘
  │ atelet                       │                     │ Snapshots: S3 over HTTP
  └──────────────┬───────────────┘                     │
                 │ Postgres: TLS, verify-full          │
                 ▼                                     ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ the Spark 10.0.2.160 (not a Node)                                │
  │ postgres :5432 (TLS)  rustfs :9000 (HTTP)  registry :5000 (HTTPS)│
  │ /srv/spark-ca (CA key, never leaves this host)                   │
  └──────────────────────────────────────────────────────────────────┘
```

## Files

| File | What it is |
|---|---|
| [`substrate-install.yaml`](substrate-install.yaml) | `ate-setup` configuration. Contains no secrets. |
| [`components/homelab/`](components/homelab/kustomization.yaml) | Kustomize Component with the homelab differences from upstream's GKE-shaped `base`: S3 to RustFS, no GKE credential provider or PodMonitoring, OTel export off. |
| [`add-homelab-component.sh`](add-homelab-component.sh) | Adds that Component to a substrate checkout's `base`. |
| [`workerpool-fw2b.yaml`](workerpool-fw2b.yaml) | Namespace `homelab` and the WorkerPool: 4 Workers, FW2B only. |
| [`counter-template.yaml`](counter-template.yaml) | Smoke-test ActorTemplate in atespace `homelab`. |
| [`spark/compose.yaml`](spark/compose.yaml) | Postgres, RustFS and the registry on the Spark. |
| [`spark/pg_hba.conf`](spark/pg_hba.conf) | Postgres access: TLS and passwords only, from the LAN. |
| [`spark/issue-certs.sh`](spark/issue-certs.sh) | Creates the Spark CA and the Postgres and registry server certificates. |
| `spark/ca.crt` | The Spark CA certificate (public). Generated in Phase 1. |
| `../patches/trusted-roots.yaml` | Talos `TrustedRootsConfig` with the Spark CA. Generated in Phase 1. |
| [`../patches/controlplane-substrate-label.yaml`](../patches/controlplane-substrate-label.yaml) | `ate.dev/workloadType=ate-control-plane` on `cp-00`. |

Prerequisites already in the main runbook:
- feature gates and `runtime-config` (§4.2);
- worker sysctls and the `hardware: fw2b` label (§4.3).

## Phase 0: Preconditions (verify only)

Kubernetes stays on 1.36 with the beta certificate APIs enabled.

```bash
kubectl api-resources | grep -i clustertrustbundle                 # must return rows
talosctl -n 10.0.2.151 read /proc/sys/user/max_user_namespaces      # 11255
kubectl get nodes -l hardware=fw2b                                  # wn-01 … wn-04
```

The FW2Bs must reach `storage.googleapis.com`. atelet downloads the gVisor bundle from the public `gs://gvisor` bucket anonymously.

## Phase 1: The Spark

On the Spark (10.0.2.160), from a copy of `install/substrate/spark/`:

**1.1 Certificates.**

```bash
sudo ./issue-certs.sh
```

This creates `/srv/spark-ca/` once (the key stays there, root-only) and issues `postgres` and `registry` certificates for `IP:10.0.2.160` into `/srv/substrate/certs/`. Copy the two public outputs back into the repo:
- `out/ca.crt` → `install/substrate/spark/ca.crt`
- `out/trusted-roots.yaml` → `install/patches/trusted-roots.yaml`

Run it again to re-issue the server certificates (825-day lifetime). The CA (10-year lifetime) is only created once.

**1.2 Secrets.** These go next to `compose.yaml` and are never committed:

```bash
umask 077
openssl rand -base64 32 > postgres-password
printf 'RUSTFS_ACCESS_KEY=substrate\nRUSTFS_SECRET_KEY=%s\n' "$(openssl rand -base64 32)" > rustfs.env
```

**1.3 Start the services.**

```bash
sudo docker compose up -d
sudo docker compose ps          # postgres healthy, rustfs and registry up
```

**1.4 Database identities.** Upstream never provisions an external database, so run its setup script once. Use two new passwords and keep them for Phase 4:

```bash
curl -fsSLO https://raw.githubusercontent.com/agent-substrate/substrate/main/pkg/postgressetup/setup.sql
sudo docker compose exec -T postgres psql -U postgres -d substrate -v ON_ERROR_STOP=1 \
  -v substrate_schema=substrate \
  -v substrate_owner_role=substrate_owner \
  -v substrate_owner_user=substrate_owner_user \
  -v substrate_owner_password="$OWNER_PW" \
  -v substrate_readwrite_role=substrate_readwrite \
  -v substrate_readwrite_user=substrate_readwrite_user \
  -v substrate_readwrite_password="$READWRITE_PW" \
  -f - < setup.sql
```

**1.5 Snapshot bucket.**

```bash
export AWS_ACCESS_KEY_ID=substrate AWS_SECRET_ACCESS_KEY='<RUSTFS_SECRET_KEY>' AWS_REGION=us-east-1
aws --endpoint-url http://10.0.2.160:9000 s3api create-bucket --bucket ate-snapshots
```

## Phase 2: Talos

Add the Spark CA to both machine configs, and the Substrate label to the control plane config. Both are standalone documents or plain patches, so this is done after `talosctl gen config` (main runbook step A6):

```bash
talosctl machineconfig patch controlplane.yaml \
  --patch @install/patches/controlplane-substrate-label.yaml -o controlplane.yaml
# trusted-roots.yaml is a standalone document starting with '---'
cat install/patches/trusted-roots.yaml >> controlplane.yaml
cat install/patches/trusted-roots.yaml >> worker.yaml

talosctl -n 10.0.2.150 apply-config -f controlplane.yaml

# workers pick up the new config on their next netboot
kubectl -n netboot create secret generic machine-config \
  --from-file=worker.yaml=./worker.yaml --dry-run=client -o yaml | kubectl apply -f -
for ip in 10.0.2.151 10.0.2.152 10.0.2.153 10.0.2.154; do
  talosctl -n "$ip" reboot; sleep 120
done
```

Verify:

```bash
kubectl get node cp-00 -L ate.dev/workloadType                     # ate-control-plane
```

The trust half can't be checked until the registry has images. The control plane pulling from `10.0.2.160:5000` in Phase 4 is the test.

## Phase 3: Workstation

```bash
# Trust the Spark CA so ko can push to the registry over HTTPS.
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain install/substrate/spark/ca.crt

git clone https://github.com/agent-substrate/substrate.git ~/src/substrate
<talos-homelab>/install/substrate/add-homelab-component.sh ~/src/substrate
cp <talos-homelab>/install/substrate/spark/ca.crt ~/src/substrate/spark-ca.crt
go install ./cmd/kubectl-ate                 # from ~/src/substrate
```

**After every `git pull`** of the checkout, run `add-homelab-component.sh` again. It's a no-op when the Component is already listed. Then check whether the `args` list in `components/homelab/kustomization.yaml` still matches upstream's `manifests/ate-install/atelet.yaml`.

## Phase 4: Install

From `~/src/substrate`:

```bash
kubectl create namespace ate-system --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ate-system create secret generic rustfs-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=substrate \
  --from-literal=AWS_SECRET_ACCESS_KEY='<RUSTFS_SECRET_KEY>'

DSN_OPTS='sslmode=verify-full&sslrootcert=/run/postgres-server-ca/server-ca.pem'
export ATE_API_POSTGRES_OWNER_CONNECTION_STRING="postgresql://substrate_owner_user:${OWNER_PW}@10.0.2.160:5432/substrate?${DSN_OPTS}"
export ATE_API_POSTGRES_READ_WRITE_CONNECTION_STRING="postgresql://substrate_readwrite_user:${READWRITE_PW}@10.0.2.160:5432/substrate?${DSN_OPTS}"

go run ./cmd/ate-setup deploy ate-system \
  --config <talos-homelab>/install/substrate/substrate-install.yaml
```

URL-encode the passwords if they contain `/`, `+` or `=`, which base64 output can. `ate-setup` builds every image with `ko`, pushes it to `10.0.2.160:5000/substrate`, and publishes `spark-ca.crt` as the Postgres server CA. Because the connection strings don't name the bundled database, it skips deploying one.

**Always use `deploy ate-system`.** The single-component redeploys (`deploy atelet` and similar) apply raw manifests without `base`, so they would drop the homelab Component's settings.

Verify:

```bash
kubectl -n ate-system get pods -o wide        # control plane on cp-00; atelet on all five Nodes
kubectl -n ate-system logs deploy/ate-api-server | grep -i -m5 migrat
kubectl get sandboxconfig gvisor-default      # upstream default, unchanged
```

## Phase 5: WorkerPool and smoke test

From `~/src/substrate`:

```bash
hack/run-tool.sh ko apply -f <talos-homelab>/install/substrate/workerpool-fw2b.yaml
kubectl -n homelab get pods -o wide           # 4 Workers, one per FW2B
kubectl ate get workers

kubectl ate create atespace homelab
hack/run-tool.sh ko resolve -f <talos-homelab>/install/substrate/counter-template.yaml \
  | kubectl ate create actor-template -f -
kubectl ate get actor-template counter -a homelab -o yaml   # wait for the Golden snapshot

kubectl ate create actor my-counter-1 -a homelab --template counter
kubectl port-forward -n ate-system svc/atenet-router 8000:80 &
curl -X POST -H 'ate-target-actor: homelab/my-counter-1' -i http://localhost:8000/
```

**The real test: does state survive a suspend and a move?**

```bash
kubectl ate suspend actor my-counter-1 -a homelab
aws --endpoint-url http://10.0.2.160:9000 s3 ls s3://ate-snapshots/homelab/counter/ --recursive
curl -X POST -H 'ate-target-actor: homelab/my-counter-1' -i http://localhost:8000/   # count continues

kubectl ate get actor my-counter-1 -a homelab   # note its worker's Node
kubectl ate suspend actor my-counter-1 -a homelab
kubectl cordon <that node>
curl -X POST -H 'ate-target-actor: homelab/my-counter-1' -i http://localhost:8000/   # resumes on another FW2B, count intact
kubectl uncordon <that node>
```

## How the pieces are configured, and why

| Setting | Choice | Why |
|---|---|---|
| Installer | `ate-setup` with `substrate-install.yaml` | Upstream's installer. `hack/install-ate.sh` is only a shim over it. |
| `base` changes | `homelab` Component added to the checkout | `ate-setup` always renders `base` outside kind mode and accepts no extra components. |
| Control-plane placement | `cordonControlPlane: true` + Talos label | Upstream's own component; no hand-written `nodeSelector` patches. No taint is needed, because the component only adds a toleration. |
| Egress credentials | `{"name":"k8s.io"}`, empty grant policy | Keys get injected outside the sandbox. Default-deny until an atespace is granted namespaces. |
| Ingress | `deprecated-insecure`, ClusterIP only | Reachable only by people who can port-forward. |
| API authorization | On, `ate-client` bootstrap owner | Only cluster admins can mint that token. |
| gVisor | Upstream `gvisor-default` | Upstream bumps the gVisor nightly together with the code that needs it. |
| WorkerPool placement | `hardware: fw2b` | Upstream refuses to restore a Snapshot onto a Worker with fewer CPU features. A NUC Snapshot would leave its Actor stuck on the NUC. |
| Worker size | 3Gi (request = limit), 0.5–1.5 CPU, one per FW2B | Fits a Claude Code-class Actor (2Gi, 1 CPU) on an 8GB / 2-core node. |
| Telemetry | OTLP export off | `base` targets GKE-managed OTel. `/metrics` and stdout logs still work. |

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Install hangs at "Waiting for podcertificate ClusterTrustBundles" | Beta certificate APIs not served (main runbook §4.2). |
| `ko` push fails with `x509: certificate signed by unknown authority` | Spark CA not trusted on the workstation (Phase 3). |
| Worker pods `ErrImagePull` from `10.0.2.160:5000` | `trusted-roots.yaml` missing from the node configs, or the FW2Bs haven't rebooted (Phase 2). |
| `ate-api-server` logs `certificate is not valid for 10.0.2.160` | Postgres certificate issued without the IP SAN. Re-run `issue-certs.sh`. |
| `ate-api-server` logs `no pg_hba.conf entry` | Connecting without TLS or as the wrong user. Check the DSN's `sslmode` and username. |
| atelet `CrashLoopBackOff` with `read-only file system` | A new GKE host path in upstream's atelet. Extend the homelab Component. |
| `ate-setup` fails with `no matches for kind` | A new GKE-only resource in `base`. Delete it in the homelab Component. |
| Actor won't resume after a move | Check `kubectl ate get workers` for free capacity on the FW2Bs; there are only 4 Workers. |
| Suspend and resume take ~20 s | Expected for a 2Gi memory Snapshot over 1GbE (main runbook §9). |
