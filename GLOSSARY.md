# talos-homelab

A single-control-plane Talos cluster whose FW2B machines netboot every boot. It also runs Agent Substrate, which multiplexes stateful agents onto those machines.

## Cluster

**Node**:
One machine that is a member of the Kubernetes cluster: `cp-00` or one of `wn-01`…`wn-04`.
_Avoid_: worker, worker node (except where Talos's own naming forces it, e.g. `worker.yaml`), host, box

**The Spark**:
The NVIDIA DGX Spark at 10.0.2.160. It is not a Node; it hosts the snapshot store, the state store and the image registry.
_Avoid_: DGX, storage node

## Agent Substrate

**Actor**:
One stateful agent instance that can be suspended out of memory and resumed on any compatible Worker.
_Avoid_: agent (when the specific managed instance is meant), sandbox, container

**ActorTemplate**:
The recipe an Actor is created from: its images, sandbox size and snapshot settings.
_Avoid_: template (unqualified), actor definition

**Atespace**:
Substrate's grouping for Actors and ActorTemplates. It is a separate thing from a Kubernetes namespace, even when the two share a name.
_Avoid_: namespace (when the Substrate grouping is meant)

**Worker**:
A pre-started sandboxed pod that waits for an Actor to be assigned to it. It holds at most one Actor at a time.
_Avoid_: worker node, sandbox pod

**WorkerPool**:
The set of Workers that share one shape and node placement.
_Avoid_: pool (unqualified), node pool

**Snapshot**:
A saved state of an Actor (memory, filesystem, or both) held in the snapshot store.
_Avoid_: checkpoint, backup

**Golden snapshot**:
The first Snapshot, taken from an ActorTemplate. New Actors start from it instead of cold-booting.
_Avoid_: base image, template snapshot
