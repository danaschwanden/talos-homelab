# Agent Substrate replacement plan

The plan for replacing the Agent Substrate part of [talos-homelab](https://github.com/danaschwanden/talos-homelab) (README §10 and `install/substrate/`) with a fresh install that matches current upstream. It's written without cluster access. Netboot and Talos sections are out of scope and stay as they are.

- **Upstream:** track `main` of [agent-substrate/substrate](https://github.com/agent-substrate/substrate).
- **Verified against:** `agent-substrate/substrate@d2b97509984c4dc2df75f128a05f221a7cf98107` (2026-10-18). When something breaks, start with `git log d2b9750..main -- manifests/ demos/counter/ cmd/ate-setup/ pkg/api/`.
- **Terms:** as defined in [GLOSSARY.md](GLOSSARY.md).
- **Key decision:** [ADR 0001](docs/adr/0001-substrate-state-on-the-spark.md), Substrate state lives on the Spark.

> **Implemented 2026-10-18** in `install/substrate/` and README §9/§10. Where this plan and those files differ, the files win. Changes found while implementing:
> - The `homelab` Component also drops atelet's GKE image-credential-provider flags and host paths (Talos's read-only root can't create them), and deletes the GKE-only `PodMonitoring`. Without that, the install fails.
> - OTel export is turned off with upstream's own `OTEL_TRACES_EXPORTER=none` / `OTEL_METRICS_EXPORTER=none` switches, not `OTEL_SDK_DISABLED`.
> - Adding the Component to the checkout is done by `add-homelab-component.sh`, since there's no `kustomize` binary.
> - New risk: Flannel doesn't enforce NetworkPolicies, so upstream's default-deny ingress policies have no effect (README §9 item 10).

## Shape

```
          cp-00 (NUC)                          wn-01 … wn-04 (FW2B)
  ┌──────────────────────────────┐      ┌──────────────────────────────┐
  │ ate-api-server  ate-controller│      │ atelet + objectstore-plugin  │
  │ atenet-router   atenet-egress │      │ 1 Worker (ateworker-gvisor)  │
  │ ate-idp-server  podcert-ctrl  │      │   3Gi, 0.5–1.5 CPU           │
  │ k8s-credential-provider       │      └──────────────┬───────────────┘
  │ atelet                        │                     │ snapshots (S3, HTTP)
  └──────────────┬───────────────┘                     │
                 │ Postgres (TLS, verify-full)          │
                 ▼                                      ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ the Spark 10.0.2.160                                              │
  │ postgres:5432 (TLS)   rustfs:9000 (HTTP)   registry:5000 (HTTPS) │
  │ /srv/spark-ca  (CA key, never leaves the host)                   │
  └──────────────────────────────────────────────────────────────────┘
```

## Decisions

| # | Area | Decision |
|---|---|---|
| 1 | Upstream | Track `main` and record the verified-against SHA (above). |
| 2 | Installer | `ate-setup` with a committed `SubstrateInstall` document. Secrets come only from environment variables. |
| 3 | Overlay gap | `ate-setup` always renders `manifests/ate-install/base` outside kind mode. One `homelab` kustomize Component is added to the checkout's `base` before every run. |
| 4 | State store | PostgreSQL on the Spark, in Docker, using upstream's pinned `postgres:18-alpine@sha256:9a8afca5…`, with a named volume. |
| 5 | DB auth | BYO database: `pkg/postgressetup/setup.sql` run by hand, two password logins (owner and read/write). |
| 6 | DB transport | TLS. The server certificate comes from the Spark CA, and the connection strings use `sslmode=verify-full`. |
| 7 | Snapshot store | RustFS on the Spark, **plain HTTP**. The `docker run` is fixed (see Phase 1). |
| 8 | Images | `ko`-built, pushed to `10.0.2.160:5000/substrate` over **HTTPS** with a Spark CA certificate. ko won't push to plain HTTP for non-localhost hosts. |
| 9 | Trust | Spark CA key only in `/srv/spark-ca/`; `ca.crt` committed. The Nodes get it via Talos `TrustedRootsConfig`; the workstation via the macOS System keychain. |
| 10 | Control-plane placement | `cordonControlPlane: true`, with `cp-00` labelled `ate.dev/workloadType=ate-control-plane` through Talos `machine.nodeLabels`. No taint. |
| 11 | Egress credentials | `{"name":"k8s.io"}` provider, with an empty (default-deny) grant policy. |
| 12 | Ingress auth | `deprecated-insecure`. `atenet-router` stays ClusterIP and is reached only through `kubectl port-forward`. |
| 13 | API authorization | On, with `ate-client` as the bootstrap owner (only cluster-admins can mint its token). |
| 14 | gVisor | Upstream `gvisor-default` SandboxConfig, unchanged. `gs://gvisor` assets come through atelet's anonymous GCS fallback, so the FW2Bs need to reach `storage.googleapis.com`. |
| 15 | WorkerPool placement | FW2B only (`nodeSelector: hardware: fw2b`). This is a *placement* rule: upstream now refuses restores onto Workers with fewer CPU features, so a Snapshot taken on the NUC would leave its Actor stuck on the NUC. |
| 16 | WorkerPool size | 4 replicas (one per FW2B). Each has memory 3Gi request = limit, CPU 500m request / 1500m limit. This fits a Claude Code-sized Actor (2Gi, 1 CPU). |
| 17 | Smoke test | Counter ActorTemplate in atespace `homelab`. WorkerPool in Kubernetes namespace `homelab`, label `workload: homelab`. |
| 18 | Kubernetes | Stays on 1.36 with the existing gates and `runtime-config` (they match upstream's kind config exactly). |
| 19 | Telemetry | OTel export disabled in the `homelab` Component. Logs go to stdout only. |
| 20 | Node sysctls | `user.max_user_namespaces` and `net.ipv4.conf.all.proxy_arp` stay as they are in §4.3. |
| 21 | Docs | README §10 shrinks to a pointer; the full runbook is in `install/substrate/README.md`, which links to its files instead of inlining them. |

## Repo changes

### New

| Path | Contents |
|---|---|
| `install/substrate/README.md` | The Substrate runbook: phases below, verification, troubleshooting. |
| `install/substrate/substrate-install.yaml` | `SubstrateInstall` document (see below). |
| `install/substrate/components/homelab/kustomization.yaml` | `kind: Component` (see below). |
| `install/substrate/workerpool-fw2b.yaml` | Namespace `homelab` + WorkerPool (see below). |
| `install/substrate/counter-template.yaml` | Counter ActorTemplate, in protojson form (see below). |
| `install/substrate/spark/ca.crt` | Spark CA certificate (public). |
| `install/substrate/spark/issue-certs.sh` | openssl script run on the Spark: creates the CA once, then issues the `postgres` and `registry` server certificates for IP `10.0.2.160`. |
| `install/substrate/spark/compose.yaml` | Postgres, RustFS and the registry as one Docker Compose project on the Spark (see Phase 1). |
| `install/substrate/spark/pg_hba.conf` | `hostssl` only, `scram-sha-256`, limited to `10.0.2.0/24`. |
| `install/patches/trusted-roots.yaml` | Talos `TrustedRootsConfig` holding `ca.crt`, appended to both machine configs. |
| `install/patches/controlplane-substrate-label.yaml` | `machine.nodeLabels: {ate.dev/workloadType: ate-control-plane}`. |

### Changed

| Path | Change |
|---|---|
| `README.md` §10 | Replaced by a short section: what Substrate is, its prerequisites (§4.2 gates, §4.3 sysctls and label), a link to `install/substrate/README.md`. |
| `README.md` §9 items 7–10 | Rewritten (see "Risk register" below). |
| `README.md` §1 table, §3.1a, §10.1 references | "Valkey" becomes "PostgreSQL on the Spark". Only Substrate rows are touched. |

### Deleted

| Path | Why |
|---|---|
| `install/substrate/ate-demo-counter.yaml` | ActorTemplate is no longer a CRD. |
| `install/substrate/manifests/ate-install/homelab/kustomization.yaml` | References Valkey and `atenet-dns`, which no longer exist upstream. Replaced by the `homelab` Component. |
| `install/substrate/sandboxconfig-gvisor-homelab.yaml` | Old schema. Upstream's default now works on an S3 backend. |
| `install/patches/patch-registry-mirror.yaml` | Wrong host (`10.0.1.50`) and a `'*'` scope. The registry is now HTTPS and trusted through `TrustedRootsConfig`. |

## Key file sketches

These sketches define the intent. Check exact field names against upstream at implementation time.

`install/substrate/substrate-install.yaml`:

```yaml
apiVersion: install.ate.dev/v1alpha1
kind: SubstrateInstall
namespace: ate-system
cordonControlPlane: true
ingressAuthMode: deprecated-insecure
atenet:
  dataplane: envoy
  egress:
    credentialProvider: '{"name":"k8s.io"}'
ko:
  dockerRepo: 10.0.2.160:5000/substrate
  defaultPlatforms: linux/amd64        # workstation is arm64, Nodes are amd64
storage:
  bucketName: ate-snapshots
ateapi:
  authz:
    enabled: true                      # bootstrapOwners left at the ate-client default
  postgres:
    schema: substrate
    serverCAFile: install/substrate/spark/ca.crt   # published as a Secret, mounted at /run/postgres-server-ca/server-ca.pem
# Not committed. Exported before each run:
#   ATE_API_POSTGRES_OWNER_CONNECTION_STRING='postgresql://substrate_owner_user:<pw>@10.0.2.160:5432/substrate?sslmode=verify-full&sslrootcert=/run/postgres-server-ca/server-ca.pem'
#   ATE_API_POSTGRES_READ_WRITE_CONNECTION_STRING='postgresql://substrate_readwrite_user:<pw>@10.0.2.160:5432/substrate?sslmode=verify-full&sslrootcert=/run/postgres-server-ca/server-ca.pem'
```

`install/substrate/components/homelab/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
  # Snapshots and sandbox assets go to RustFS on the Spark, not GCS.
  - patch: |-
      apiVersion: apps/v1
      kind: DaemonSet
      metadata: {name: atelet, namespace: ate-system}
      spec:
        template:
          spec:
            initContainers:
            - name: objectstore-plugin
              env:
              - {name: ATE_STORAGE_BACKEND, value: s3}
              - {name: AWS_REGION, value: us-east-1}
              - {name: AWS_ENDPOINT_URL, value: "http://10.0.2.160:9000"}
              - {name: AWS_S3_USE_PATH_STYLE, value: "true"}
              - name: AWS_ACCESS_KEY_ID
                valueFrom: {secretKeyRef: {name: rustfs-credentials, key: AWS_ACCESS_KEY_ID}}
              - name: AWS_SECRET_ACCESS_KEY
                valueFrom: {secretKeyRef: {name: rustfs-credentials, key: AWS_SECRET_ACCESS_KEY}}
  # base points at GKE-managed OTel, which doesn't exist here.
  - patch: |-
      apiVersion: v1
      kind: ConfigMap
      metadata: {name: ate-otel-config, namespace: ate-system}
      data:
        OTEL_EXPORTER_OTLP_ENDPOINT: ""
        OTEL_SDK_DISABLED: "true"
```

`install/substrate/workerpool-fw2b.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: homelab
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: ate.dev/v1alpha1
kind: WorkerPool
metadata:
  name: fw2b
  namespace: homelab
  labels:
    workload: homelab
spec:
  replicas: 4                          # one Worker per FW2B
  workerImage: ko://go.ate.dev/substrate/cmd/ateworker-gvisor
  sandboxClasses:
  - name: gvisor                       # follows the gvisor-default class default
  template:
    nodeSelector:
      hardware: fw2b                   # placement rule, see Decision 15
    resources:
      requests: {cpu: 500m, memory: 3Gi}
      limits:   {cpu: 1500m, memory: 3Gi}
```

`install/substrate/counter-template.yaml` (created with `ko resolve -f … | kubectl ate create actor-template -f -`):

```yaml
metadata:
  atespace: homelab
  name: counter
workerSelector:
  matchLabels:
    workload: homelab
containers:
- name: counter
  image: ko://go.ate.dev/substrate/demos/counter
  command: [/ko-app/counter]
  wakeupProbe:
    httpGet: {path: /readyz, port: 80}
  volumeMounts:
  - {name: data, mountPath: /home/counter}
resources:
  limits:
  - {name: cpu, quantity: "1"}
  - {name: memory, quantity: 512Mi}
snapshotConfig:
  preferredFidelity: SNAPSHOT_FIDELITY_MEMORY
  storageLocation: gs://ate-snapshots/homelab/counter/   # gs:// on purpose: the scheme is a location string; atelet's backend decides where it goes
volumes:
- name: data
  durableDir: {}
```

## Runbook phases

These phases become `install/substrate/README.md`.

### Phase 0: Preconditions (verify only)

- `kubectl get clustertrustbundles` returns a resource type rather than an error. Nothing about Kubernetes or the gates changes.
- `talosctl -n 10.0.2.151 read /proc/sys/user/max_user_namespaces` returns `11255`.
- The FW2Bs can reach `storage.googleapis.com` (gVisor assets).

### Phase 1: The Spark

1. Run `issue-certs.sh` on the Spark. It creates `/srv/spark-ca/` (key mode 0600, root-only) and issues the `postgres` and `registry` certificates for `IP:10.0.2.160`. Copy `ca.crt` into the repo.
2. Start `compose.yaml` with three services:
   - **postgres:** upstream's pinned image, volume `ate-postgres-data`, the server certificate and key mounted, `ssl=on`, our `pg_hba.conf`, and the superuser password from a file mounted via Compose `secrets:`.
   - **rustfs:** `rustfs/rustfs:1.0.0-beta.3` pinned by digest, volume `rustfs-data`, port 9000, and credentials from a mounted secret file. This replaces the old `docker run` with its `\ #` comment bug and its unmounted secret file.
   - **registry:** `registry:3`, volume `registry-data`, with `REGISTRY_HTTP_TLS_CERTIFICATE` / `REGISTRY_HTTP_TLS_KEY` set.
3. Run `setup.sql` against Postgres with `psql`, giving the two login passwords. This creates schema `substrate`, the `substrate_owner` and `substrate_readwrite` roles, and the `substrate_owner_user` and `substrate_readwrite_user` logins.
4. Create bucket `ate-snapshots` in RustFS.

### Phase 2: Talos

1. Append `install/patches/trusted-roots.yaml` to `controlplane.yaml` and `worker.yaml`, and `controlplane-substrate-label.yaml` to `controlplane.yaml`.
2. `talosctl apply-config` on `cp-00`. Refresh the `machine-config` Secret and reboot the FW2Bs one at a time (§10.4 / §8.1 pattern).
3. Verify: `kubectl get node cp-00 -L ate.dev/workloadType`, and that an image pull from `10.0.2.160:5000` succeeds.

### Phase 3: Workstation

1. Trust `ca.crt` in the macOS System keychain.
2. Clone `agent-substrate/substrate` (`main`).
3. Add the component: `cd manifests/ate-install/base && kustomize edit add component <repo>/install/substrate/components/homelab`. Repeat this after every `git pull`.

### Phase 4: Install

1. `kubectl create namespace ate-system`, then create the `rustfs-credentials` Secret.
2. Export the two `ATE_API_POSTGRES_*_CONNECTION_STRING` variables.
3. Run `go run ./cmd/ate-setup deploy ate-system --config <repo>/install/substrate/substrate-install.yaml`.
4. Check that every control-plane pod is on `cp-00`, atelet is running on all five Nodes, and `ate-api-server` logs a successful migration against the Spark.

### Phase 5: WorkerPool and smoke test

1. `ko apply -f install/substrate/workerpool-fw2b.yaml`. Expect 4 Workers, one per FW2B.
2. Create the atespace `homelab`, then the counter ActorTemplate. Wait for the Golden snapshot (`kubectl ate get actor-template counter -a homelab`).
3. `kubectl ate create actor my-counter-1 -a homelab --template counter`.
4. `kubectl port-forward -n ate-system svc/atenet-router 8000:80`, then `curl -X POST -H 'ate-target-actor: homelab/my-counter-1' http://localhost:8000/`.
5. Suspend, then resume. The count must survive.
6. Check that the Snapshot exists in `s3://ate-snapshots/homelab/counter/`.
7. Cordon the Actor's Node, then resume. The Actor must come back on a different FW2B, with its count intact.

## Risk register (replaces §9 items 7–10)

7. **The Spark is a single point of failure for all Actor state.** Postgres (which Actors exist, and which Snapshot is current for each) and RustFS (the Snapshots) live on one host. Back them up and restore them together, with `/srv/spark-ca`. See ADR 0001.
8. **Tracking `main`.** Upstream changes manifests, field names and image paths frequently. The verified-against SHA marks the last known-good point.
9. **Large Snapshots over 1GbE.** A 2Gi memory Snapshot is about 20 seconds each way. Resume won't be sub-second.
10. **Upstream changes the BYO database requirements.** `ate-setup` won't migrate roles or grants on the Spark. Re-check `docs/postgres.md` after pulling `main`.

## Follow-ups

- Talos 1.14 + Kubernetes 1.37, then remove the feature gates and `runtime-config` (Talos 1.13 supports at most 1.36).
- `ingressAuthMode: static-mtls` once an in-cluster caller exists.
- Set `ateapi.authz.bootstrapOwners` to real principals.
- Spark backups: nightly `pg_dump` plus bucket sync plus `/srv/spark-ca`, copied to a second machine, with a restore test.
- Observability: upstream's kind `otel-collector` and Prometheus, pinned to `cp-00`.
- A Claude Code ActorTemplate (2Gi / 1 CPU) with an egress credential grant for its API key.
