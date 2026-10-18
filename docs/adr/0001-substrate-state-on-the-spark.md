---
status: accepted
---

# Substrate state lives on the Spark, behind a hand-built CA

Agent Substrate's state store (PostgreSQL) and snapshot store (RustFS) both run as Docker containers on the Spark, outside the cluster, rather than as in-cluster workloads on `cp-00`. The Nodes are disposable: the FW2Bs netboot and can be wiped at any time, and the NUC is a single control plane. The Spark has the disk, and it survives a cluster rebuild. Because the database sits outside the cluster, upstream's passwordless Pod Certificate auth for Postgres doesn't apply. We use password logins over TLS with `verify-full` instead, and the HTTPS image registry needs a trust root too. So a small self-signed CA lives on the Spark (key only under `/srv/spark-ca/`, `ca.crt` committed). The Nodes trust it through `TrustedRootsConfig`, and the workstation trusts it through its keychain.

## Considered Options

- **Bundled in-cluster Postgres on `cp-00`** (upstream's default, a `local-path` PVC). Rejected: it ties Actor state to the one control-plane machine, and it splits the two halves of Actor state across two hosts.
- **Pod Certificate auth to an external Postgres.** Rejected: it would need the Spark to trust the cluster's podcert signer CA. Upstream documents that only for the bundled pod.
- **RustFS behind TLS as well.** Rejected for now: RustFS stays on plain HTTP on the trusted LAN.

## Consequences

- The Spark is a single point of failure for all Actor state. Postgres, RustFS and `/srv/spark-ca` must be backed up and restored together. A Postgres restore that doesn't match the bucket leaves orphaned Snapshots, and the reverse leaves Actors pointing at missing ones.
- Upstream's installer does nothing for this database: schema, roles and logins come from running `pkg/postgressetup/setup.sql` by hand, and upgrades that change those requirements must be noticed and applied manually.
- Rotating the CA means re-issuing the Postgres and registry certificates, re-applying `TrustedRootsConfig` to every Node, and updating the workstation keychain.
