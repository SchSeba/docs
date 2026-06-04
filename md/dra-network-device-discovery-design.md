# DRA Network Device Discovery and ResourceSlice Design

> **Status:** Selected Design  
> **Companion documents:**
> [DRA Chainable Networking Proposal](dra-chainable-networking-proposal.md) |
> [Discovery Brainstorm](dra-resourceslice-discovery-brainstorm.md)  
> **Upstream dependencies:**
> [KEP 4815 — SharedCounters](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/4815-dra-scalable-shared-counters) (GA, K8s 1.35+) |
> [KEP 5075 — Consumable Capacity](https://github.com/kubernetes/enhancements/blob/master/keps/sig-scheduling/5075-dra-consumable-capacity/README.md) (Beta, K8s 1.36) |
> [KEP 5941 — Shared Consumable Capacity](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/5941-scalable-dra-shared-consumable-capacity) |
> [KEP 5491 — DRAListTypeAttributes](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/#list-type-attributes) (Alpha, K8s 1.36)

---

## Table of Contents

1. [Overview and Design Principles](#1-overview-and-design-principles)
2. [DeviceExposurePolicy CRD Schema](#2-deviceexposurepolicy-crd-schema)
3. [How Exclusion Groups Work: The Dual-Device Pattern](#3-how-exclusion-groups-work-the-dual-device-pattern)
4. [How the Driver Uses Policies](#4-how-the-driver-uses-policies)
5. [Examples](#5-examples)
   - [5.1 Simple SR-IOV VFs (exclusive, one CNI)](#51-example-1-simple-sr-iov-vfs)
   - [5.2 SR-IOV VFs with multiple CNI options](#52-example-2-sr-iov-vfs-with-multiple-cni-options)
   - [5.3 PF as macvlan parent (shared, one CNI)](#53-example-3-pf-as-macvlan-parent)
   - [5.4 PF with macvlan AND ipvlan (exclusion group)](#54-example-4-pf-with-macvlan-and-ipvlan-exclusion-group)
   - [5.5 PF with macvlan AND host-device passthrough](#55-example-5-pf-with-macvlan-and-host-device-passthrough)
   - [5.6 Complex — PF with VFs + macvlan + host-device](#56-example-6-pf-with-vfs--macvlan--host-device)
   - [5.7 VF as bridge port OR sriov exclusive](#57-example-7-vf-as-bridge-port-or-sr-iov)
   - [5.8 Excluding cluster CNI interfaces](#58-example-8-excluding-cluster-cni-interfaces)
   - [5.9 OVN-Kubernetes networks via our generic driver](#59-example-9-ovn-kubernetes-networks-via-our-generic-driver)
6. [Complete Reference Node](#6-complete-reference-node)
7. [Open Questions](#7-open-questions)

---

## 1. Overview and Design Principles

This document specifies how the DRA network driver discovers host network
devices and publishes them as ResourceSlices for scheduler-aware allocation.

### The Cardinal Rule: The Driver Is Generic

The DRA network driver is a **generic interface discovery engine**. It walks
`/sys/class/net`, reads sysfs and netlink, and produces a bag of raw facts
about every interface on the node: name, MAC, MTU, PCI address, NUMA node,
driver, link speed, parent PF, VF index, bridge membership, etc.

**The driver does NOT know:**

- What a "macvlan" is, or how many can fit on an interface.
- That `sriov-cni` moves a VF and `host-device` moves a PF.
- That macvlan and ipvlan conflict on the same parent.
- That allocating a PF for passthrough destroys its VFs.
- How much capacity a bridge has, or what "ports" means.

**All of that knowledge lives in the `DeviceExposurePolicy` CRD.** The
cluster administrator creates policies that tell the driver:

1. Which devices to expose (and which to hide).
2. Whether a device supports multiple simultaneous allocations.
3. What capacity counters to publish and how much each allocation consumes.
4. Which CNI plugins are compatible with the device.
5. Which plugins conflict with each other (exclusion groups).

The driver reads these policies and mechanically translates them into
ResourceSlice fields. It does not interpret or validate the CNI-level
semantics — it is a policy executor, not a policy author.

### Why This Matters

- **Extensibility.** New CNI plugins, new sharing patterns, or new
  conflict rules require only a new `DeviceExposurePolicy` — no driver
  code changes.
- **Correctness by construction.** The admin who understands the hardware
  and the CNI ecosystem encodes that knowledge once. The driver applies
  it uniformly.
- **Debuggability.** If a device has the wrong capacity or the wrong
  `supportedCNIs`, the admin inspects the policy, not the driver source.

### Other Design Decisions

1. **Every real host interface is a device.** PFs, VFs, bridges, regular NICs,
   and VLAN interfaces are published as real devices — not synthetic slots.

2. **Shared devices use `allowMultipleAllocations: true` with consumable
   capacity** (KEP 5075, Beta K8s 1.36). No synthetic slot duplication.

3. **Exclusive devices use normal allocation.** One pod takes the whole device.
   When an exclusive plugin (e.g. `host-device`) coexists with a shared
   plugin (e.g. `macvlan`) on the same physical interface, the driver
   publishes **two device entries** that share a counter set. The exclusive
   entry's `consumesCounters` drains all shared capacity, enforcing
   mutual exclusion at scheduling time.

4. **PF/VF mutual exclusion uses shared counters** (KEP 4815, GA K8s 1.35+).
   Slot counter `exclusion-slots = numVFs + 1`. PF consumes all; each VF
   consumes 1.

5. **Bandwidth sharing uses shared counters** with `requestPolicy` and
   `valueFrom` (KEP 5941).

6. **Deny-by-default.** If no `DeviceExposurePolicy` matches a device, it
   is not published in any ResourceSlice.

7. **CNI compatibility validated at scheduling time.** Generated DeviceClasses
   include `supportedCNIs.includes("<cni-type>")` in CEL selectors.

---

## 2. DeviceExposurePolicy CRD Schema

### 2.1 Full CRD Definition

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: <policy-name>          # cluster-scoped
spec:
  # ── Targeting ──

  # Which nodes this policy applies to. Optional; defaults to all nodes.
  nodeSelector:
    matchLabels:
      <key>: <value>

  # Higher priority wins when multiple expose policies match the same device.
  # Range: 0–1000. Default: 100.
  priority: 100

  # CEL expression evaluated against each discovered device's raw attributes.
  # The expression has access to device.attributes["dra.networking"].<attr>.
  selector:
    cel: "<CEL expression>"

  # "expose" publishes the device; "exclude" hides it. Default: "expose".
  action: expose   # | exclude

  # ── Exposure Configuration (only when action=expose) ──
  exposure:
    # Suffix appended to the interface name to form the device entry name.
    # Use when multiple policies match the same physical device to create
    # separate entries (e.g. "-macvlan" and "-passthrough" for the same PF).
    # Default: "" (no suffix — device name = interface name).
    deviceNameSuffix: ""

    # Whether the device supports multiple simultaneous allocations.
    # The driver sets allowMultipleAllocations on the ResourceSlice device.
    # Default: false.
    allowMultipleAllocations: false

    # Capacity counters published on the device.
    # Each entry becomes a capacity field on the ResourceSlice device.
    # Only meaningful when allowMultipleAllocations is true (or when an
    # exclusive plugin needs to consume all of a shared capacity).
    capacity:
      <counterName>:
        value: "<total capacity>"
        requestPolicy:                  # optional
          default: "<default per claim>"
          validRange:
            min: "<minimum>"
            max: "<maximum>"
            step: "<granularity>"

    # CNI plugins that are valid for this device.
    # Published as the dra.networking/supportedCNIs attribute.
    # Each plugin declares how much capacity it consumes per allocation.
    supportedCNIPlugins:
      - name: <cni-binary-name>
        # How much of each capacity counter this plugin consumes per
        # allocation. Keys must match entries in `capacity` above.
        # If omitted for a counter, the plugin uses the counter's
        # requestPolicy.default.
        consumePerAllocation:
          <counterName>: <amount>
        # If true, this plugin takes the entire device exclusively.
        # When a policy has BOTH exclusive and non-exclusive plugins,
        # the driver creates SEPARATE device entries:
        #   - "<ifName>" for shared plugins (allowMultipleAllocations: true)
        #   - "<ifName>-<suffix>" for exclusive plugins (normal device)
        # Both entries share a counter set so allocating the exclusive
        # device drains all shared capacity, enforcing mutual exclusion.
        # Default: false.
        exclusive: false

    # Exclusion group label. When multiple policies matching the same
    # physical device declare the SAME exclusionGroup value, the driver
    # links them via shared counters: allocating one persona drains the
    # other persona's mirrored capacity in the shared counter set.
    #
    # Example: pf1-macvlan and pf1-ipvlan both set
    # exclusionGroup: "rx-handler" → allocating a macvlan drains all
    # ipvlan capacity and vice versa.
    #
    # If omitted, the device entry is independent — no cross-draining.
    exclusionGroup: ""

    # Additional attributes injected into the ResourceSlice device entry.
    additionalAttributes:
      <key>: <value>
```

### 2.2 Field Semantics

| Field | Required | Default | Description |
|---|---|---|---|
| `nodeSelector` | No | All nodes | Standard label selector to scope the policy to specific nodes |
| `priority` | No | 100 | Conflict resolution among matching `expose` policies. Higher wins. |
| `selector.cel` | Yes | — | CEL expression against the device's discovered attributes |
| `action` | No | `expose` | `expose` publishes the device; `exclude` hides it |
| `exposure.deviceNameSuffix` | No | `""` (no suffix) | Appended to the interface name to form the device entry name. Enables multiple policies to create separate device entries for the same physical interface. |
| `exposure.allowMultipleAllocations` | No | `false` | Maps directly to the ResourceSlice device field |
| `exposure.capacity` | No | — | Capacity counters for shared devices |
| `exposure.supportedCNIPlugins` | No | — | CNI compatibility list; flows into `supportedCNIs` attribute |
| `exposure.supportedCNIPlugins[].exclusive` | No | `false` | Exclusive plugins consume all capacity counters |
| `exposure.supportedCNIPlugins[].consumePerAllocation` | No | — | Per-counter consumption amounts |
| `exposure.exclusionGroup` | No | `""` (none) | Label linking policies that exclude each other. Policies matching the same device with the same `exclusionGroup` value share a counter set where each drains the other's capacity. |
| `exposure.additionalAttributes` | No | — | Extra attributes merged into the device |

### 2.3 Policy Resolution

```
For each discovered device on this node:
  1. Collect all DeviceExposurePolicy CRs whose nodeSelector matches.
  2. Evaluate selector.cel against the device's discovered attributes.
  3. Collect all policies where the selector returns true.
  4. If ANY matching policy has action=exclude → device is HIDDEN. Stop.
  5. If NO policy matches → device is HIDDEN (deny-by-default). Stop.
  6. Among matching expose policies:
     a. Group by deviceNameSuffix value (including empty = no suffix).
     b. Within each group, pick the highest priority.
        Ties broken by lexicographic policy name.
     c. Each group winner produces ONE device entry.
  7. If multiple groups produce entries for the same physical device,
     all entries share a counter set for mutual exclusion.
```

| Rule | Rationale |
|---|---|
| Deny-by-default | Undeclared devices are never accidentally exposed |
| Exclusion always wins | Infrastructure protection cannot be overridden by an expose policy |
| Highest priority wins | Predictable, auditable conflict resolution for expose policies |
| Cluster-scoped | Network device exposure is a platform-level concern |

---

## 3. How Exclusion Groups Work: The Dual-Device Pattern

All mutual exclusion in this design follows a single pattern:
**separate device entries sharing a counter set**.

### 3.1 The Pattern

When two usage modes of the same physical interface conflict, the driver
publishes them as **separate device entries** in the ResourceSlice. The
connection between them is established by two mechanisms:

**Mechanism A — `exclusionGroup` (shared vs shared):**
Two multi-alloc policies declaring the same `exclusionGroup` value.
Each device's `consumesCounters` drains the other's mirrored capacity.

```
exclusionGroup: "rx-handler" on both policies

  ┌──────────────────────┐    sharedCounters:     ┌──────────────────────┐
  │ enp3s0f1-macvlan     │    ┌──────────────┐    │ enp3s0f1-ipvlan      │
  │ allowMultipleAlloc   │◄──►│ macvlan: 64  │◄──►│ allowMultipleAlloc   │
  │ capacity: macvlan=64 │    │ ipvlan: 64   │    │ capacity: ipvlan=64  │
  │ consumesCounters:    │    └──────────────┘    │ consumesCounters:    │
  │   ipvlan: 64 (all)  │                         │   macvlan: 64 (all) │
  └──────────────────────┘                         └──────────────────────┘
```

**Mechanism B — `exclusive: true` (shared vs exclusive):**
An exclusive policy's device drains ALL shared counters automatically.
No `exclusionGroup` needed — `exclusive: true` implies "drain everything."

```
  ┌──────────────────────┐    sharedCounters:     ┌──────────────────────┐
  │ enp3s0f0-macvlan     │    ┌──────────────┐    │ enp3s0f0-passthrough │
  │ allowMultipleAlloc   │◄──►│ macvlan: 64  │◄──►│ exclusive            │
  │ capacity: macvlan=64 │    └──────────────┘    │ consumesCounters:    │
  │                      │                         │   macvlan: 64 (all) │
  └──────────────────────┘                         └──────────────────────┘
```

**Mechanism C — PF/VF hardware mutex (automatic):**
The driver auto-creates `exclusion-slots` from PF/VF sysfs relationships.
No policy field needed.

| Conflict Type | Mechanism | Policy Field | Example |
|---|---|---|---|
| shared vs shared (macvlan vs ipvlan) | Cross-drain via `exclusionGroup` | `exclusionGroup: "rx-handler"` | Example 4 |
| shared vs exclusive (macvlan vs host-device) | Exclusive drains all counters | `exclusive: true` | Example 5 |
| PF vs VFs (hardware) | Slot counter from sysfs | (automatic) | Example 6 |

### 3.2 Why Not Single-Device Cross-Consumption?

Earlier iterations tried encoding exclusion on a **single device** by
having each CNI plugin's `consumePerAllocation` drain the other's counter.
This fails because DRA capacity consumption is **per-allocation**, not
"per first allocation":

- 1st macvlan consumes `macvlans: 1, ipvlans: 64` → ipvlans = 0. OK.
- 2nd macvlan consumes `macvlans: 1, ipvlans: 64` → but ipvlans is
  already 0. **Fails.**

The dual-device pattern avoids this because `consumesCounters` on a
device with `allowMultipleAllocations: true` is charged **once per device
lifecycle** (when the device first enters the allocated state), not per
claim. Subsequent allocations of the same multi-alloc device only consume
from the device's own `capacity` field.

### 3.3 How `consumesCounters` Works with `allowMultipleAllocations`

This is the critical DRA behavior that makes the pattern work (KEP 5075):

1. Device `enp3s0f0-macvlan` has `allowMultipleAllocations: true`.
2. Its `consumesCounters` says: drain `ipvlan-capacity: 64` from the
   shared counter set.
3. **First allocation** of `enp3s0f0-macvlan`: scheduler charges
   `ipvlan-capacity: 64` from the shared set AND `macvlans: 1` from
   the device's own capacity. → ipvlan-capacity = 0, macvlans = 63.
4. **Second allocation** of the same device: scheduler charges only
   `macvlans: 1` from the device's capacity. The `consumesCounters`
   was already charged. → macvlans = 62.
5. **ipvlan device** tries to allocate: its `consumesCounters` needs
   `macvlan-capacity: 64`, but the macvlan device's counter already
   consumed from the shared set... wait — does this work?

> **Open question:** We need to verify that DRA's `consumesCounters`
> on a multi-alloc device is charged only once (on first allocation)
> vs per-allocation. If it's per-allocation, the dual-device pattern
> has the same problem as single-device cross-consumption. In that case,
> the fallback is **admin-separated policies** (one CNI type per
> physical interface) with a **driver-side safety net** at prepare time.

### 3.4 Fallback: Admin-Separated Policies

If `consumesCounters` is per-allocation (not per-device-lifecycle), the
simplest correct approach is: **don't put conflicting CNI types on the
same physical interface.** The admin creates separate policies scoped
to different interfaces or nodes:

```yaml
# Policy for macvlan-mode PFs (e.g. PF1)
name: pf1-macvlan
selector:
  cel: device.attributes["dra.networking"].ifName == "enp3s0f1"
supportedCNIPlugins: [{name: macvlan}]

# Policy for ipvlan-mode PFs (e.g. PF2)
name: pf2-ipvlan
selector:
  cel: device.attributes["dra.networking"].ifName == "enp3s0f2"
supportedCNIPlugins: [{name: ipvlan}]
```

No conflict is possible because macvlan and ipvlan are on different
physical interfaces. The driver adds a **safety net** at
`NodePrepareResources`: if a device is already in use by a conflicting
CNI type, reject with a clear error.

### 3.5 Summary

| Approach | Enforcement | Works? |
|---|---|---|
| **Dual-device with shared counters** | Scheduling time | Yes if `consumesCounters` is per-device-lifecycle (verify with KEP 5075) |
| **Admin-separated policies** | N/A (conflict impossible) | Always works |
| **Driver-side check** | Prepare time (safety net) | Always works, but late failure |

**Recommendation:** Design for dual-device pattern. Verify
`consumesCounters` behavior with upstream. Use admin-separated policies
as the guaranteed-correct fallback, with driver-side check as the
universal safety net.

---

## 4. How the Driver Uses Policies

The driver is a mechanical translator. It takes raw discovered attributes
plus the winning `DeviceExposurePolicy` and produces a ResourceSlice device
entry. This section specifies the translation rules.

### 4.1 Attribute Translation

The driver publishes every discovered attribute under the `dra.networking`
domain. These are raw facts from sysfs/netlink — the driver does not
interpret them:

| Discovered Fact | ResourceSlice Attribute | Source |
|---|---|---|
| Interface name | `dra.networking/ifName` | `/sys/class/net/<if>` |
| MAC address | `dra.networking/mac` | netlink |
| MTU | `dra.networking/mtu` | `/sys/class/net/<if>/mtu` |
| Link speed | `dra.networking/linkSpeed` | `ethtool` (Mbps) |
| Operational state | `dra.networking/operState` | netlink |
| PCI BDF address | `dra.networking/pciAddress` | sysfs device symlink |
| NUMA node | `dra.networking/numaNode` | sysfs `numa_node` |
| PCIe root complex | `device.k8s.io/pcieRoot` | PCI topology walk |
| PCI vendor ID | `dra.networking/vendor` | PCI config |
| PCI product ID | `dra.networking/product` | PCI config |
| Kernel driver | `dra.networking/driver` | sysfs driver symlink |
| Interface type | `dra.networking/type` | Classification algorithm (pf/vf/bridge/vlan/bond/nic) |
| RDMA capable | `dra.networking/rdma` | `/sys/class/infiniband` |
| SR-IOV capable | `dra.networking/sriovCapable` | `sriov_totalvfs > 0` |
| Configured VF count | `dra.networking/numVFs` | `sriov_numvfs` |
| Parent PF name | `dra.networking/pfName` | sysfs `physfn` |
| VF index | `dra.networking/vfIndex` | sysfs virtfn index |
| Bridge name | `dra.networking/bridgeName` | interface name (for bridges) |
| Bridge type | `dra.networking/bridgeType` | `linux` or `ovs` |
| VLAN filtering | `dra.networking/vlanFiltering` | sysfs `vlan_filtering` |
| Master bridge | `dra.networking/masterBridge` | sysfs `master` symlink |

### 4.2 Policy-Driven Fields

These ResourceSlice fields are set **entirely** from the `DeviceExposurePolicy`.
The driver does not compute them from hardware — it copies them from the policy:

| ResourceSlice Field | Source in Policy |
|---|---|
| `allowMultipleAllocations` | `exposure.allowMultipleAllocations` |
| `capacity` | `exposure.capacity` |
| `dra.networking/supportedCNIs` attribute | Names from `exposure.supportedCNIPlugins[].name` |
| Additional attributes | `exposure.additionalAttributes` |

### 4.3 SharedCounters: Automatic from PF/VF Relationship

The driver knows one structural fact: PF/VF parent-child relationships
(from sysfs). When it discovers a PF with VFs, it **automatically** creates
a shared counter set with `exclusion-slots = numVFs + 1`. The PF device
consumes all slots; each VF consumes 1.

This is the **only** CNI-independent knowledge the driver applies. It is a
hardware fact (moving a PF destroys its VFs), not a CNI-specific fact.

The policy can add **additional** shared counters to this set (bandwidth,
macvlan capacity). The driver merges them.

### 4.4 Translation Algorithm

```
INPUT: discovered device D, all DeviceExposurePolicies on this node
OUTPUT: zero or more device entries in the ResourceSlice

─── Phase 1: Policy Resolution ───

1. Collect all policies whose nodeSelector matches AND selector.cel
   returns true for D.
2. If ANY matching policy has action=exclude → publish nothing. STOP.
3. If NO policy matches → publish nothing (deny-by-default). STOP.
4. Group remaining expose policies by deviceNameSuffix value.
   Within each group, keep only the highest-priority policy.
   Result: a set of winning policies, one per suffix.

─── Phase 2: Build Shared Counter Set ───

If D is a PF with VFs, OR if multiple winning policies match D:

5. Create a shared counter set named "<D.ifName>-counters".

6. PF/VF hardware mutex (automatic, CNI-independent):
   If D is a PF with numVFs > 0:
     Add counter: exclusion-slots = numVFs + 1

7. Bandwidth (automatic if PF):
   If D is a PF with known link speed:
     Add counter: bandwidth = linkSpeed (Mbps)
     Set requestPolicy from policy if provided, else default fair-share.

8. Capacity mirroring (for cross-draining between personas):

   Determine if mirroring is needed:
   - multiAllocPolicies = winning policies where allowMultipleAllocations == true
   - exclusivePolicies = winning policies where allowMultipleAllocations == false
   - hasExclusionGroup = any policy has non-empty exclusionGroup

   Mirror if: len(winning policies) > 1  (multiple personas exist for D)

   For each winning multi-alloc policy P:
     For each counter C in P.exposure.capacity:
       Add counter: "<C.name>-capacity" = C.value
       to the shared counter set.

   This mirrors the device-level capacity into the shared counter set
   so that:
   - Exclusive device entries can drain it (step 11 — Example 5/6).
   - Exclusion-group peers can cross-drain it (step 10 — Example 4).

─── Phase 3: Build Device Entries ───

For each winning policy P:

9. Create a device entry with:
   - name = D.ifName + P.deviceNameSuffix (or just D.ifName if no suffix)
   - attributes = D's raw attributes + P.additionalAttributes
   - dra.networking/supportedCNIs = [p.name for p in P.supportedCNIPlugins]

10. If P.allowMultipleAllocations == true:
    - Set allowMultipleAllocations = true
    - Set capacity = P.exposure.capacity (verbatim copy)
    - If P.exclusionGroup is non-empty:
        Set consumesCounters: for each OTHER policy Q matching D
        that has the SAME exclusionGroup value, drain Q's mirrored
        capacity counter to its max value.
        (This is the exclusion group mechanism — Example 4.)
    - If P.exclusionGroup is empty: no cross-draining.

11. If P.allowMultipleAllocations == false (exclusive):
    - No allowMultipleAllocations on the device (normal exclusive).
    - Set consumesCounters: drain ALL counters in the shared counter set
      to their max values.
      (This blocks all VFs, all macvlans, all bandwidth — Example 5/6.)

─── Phase 4: VF Device Entries ───

12. For each VF of D (if D is a PF):
    Find the winning policy that matches the VF (separate CEL evaluation).
    Create a VF device entry:
    - name = VF's interface name
    - attributes = VF's raw attributes + policy's additionalAttributes
    - consumesCounters from the PARENT PF's shared counter set:
        exclusion-slots: 1
        bandwidth: valueFrom (if bandwidth counter exists)

─── Phase 5: Publish ───

13. Publish all device entries in the ResourceSlice, grouped by pool
    (one pool per PF, one pool per standalone device).
```

> **Rule: one device entry per policy, one policy per allocation
> semantic.** A physical interface that supports both shared and exclusive
> access gets separate policies with different `deviceNameSuffix` values.
> Each policy produces one device entry. All entries for the same physical
> interface share a counter set.

---

## 5. Examples

Each example shows: the admin's `DeviceExposurePolicy`, the resulting
ResourceSlice device entry the driver publishes, and an explanation of
how the policy fields map to ResourceSlice fields.

### 5.1 Example 1: Simple SR-IOV VFs

**Scenario:** VFs on `enp3s0f0` for `sriov` CNI only. Each VF is exclusively
allocated to one pod.

#### DeviceExposurePolicy

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: sriov-vfs-pf0
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "vf" &&
      device.attributes["dra.networking"].pfName == "enp3s0f0"
  action: expose
  exposure:
    allowMultipleAllocations: false
    supportedCNIPlugins:
      - name: sriov
        exclusive: true
```

#### Resulting ResourceSlice Device Entry

```yaml
- name: enp3s0f0v0
  basic:
    attributes:
      dra.networking/type:
        string: "vf"
      dra.networking/ifName:
        string: "enp3s0f0v0"
      dra.networking/pfName:
        string: "enp3s0f0"
      dra.networking/vfIndex:
        int: 0
      dra.networking/pciAddress:
        string: "0000:03:00.2"
      dra.networking/numaNode:
        int: 0
      dra.networking/rdma:
        bool: true
      dra.networking/vendor:
        string: "15b3"
      dra.networking/product:
        string: "101e"
      dra.networking/driver:
        string: "mlx5_core"
      dra.networking/supportedCNIs:
        stringSlice:
          - sriov
      device.k8s.io/pcieRoot:
        string: "pci0000:00"
  consumesCounters:
    - counterSet: pf0-counters
      counters:
        exclusion-slots:
          value: 1
```

#### Explanation

- **All plugins are exclusive → single device entry, no multi-alloc.**
  When every plugin in a policy has `exclusive: true`, the device stays
  a normal exclusive DRA device. No `allowMultipleAllocations`, no
  capacity counters on the device itself. The dual-entry pattern (Example 5)
  is only needed when exclusive and shared plugins coexist.
- `supportedCNIs: ["sriov"]` — published as a list-type attribute.
- The `exclusion-slots` shared counter comes from the driver's automatic
  PF/VF relationship detection, not from the `exclusive` flag. This is
  the PF/VF hardware mutex, independent of CNI plugins.

---

### 5.2 Example 2: SR-IOV VFs with Multiple CNI Options

**Scenario:** VFs support both `sriov` (configures VLAN/trust/spoofchk then
moves VF) and `host-device` (raw move without SR-IOV config). Both are
exclusive.

#### DeviceExposurePolicy

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: sriov-vfs-multi-cni
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "vf" &&
      device.attributes["dra.networking"].pfName == "enp3s0f0"
  action: expose
  exposure:
    allowMultipleAllocations: false
    supportedCNIPlugins:
      - name: sriov
        exclusive: true
      - name: host-device
        exclusive: true
```

#### Resulting ResourceSlice Device Entry

```yaml
- name: enp3s0f0v0
  basic:
    attributes:
      dra.networking/type:
        string: "vf"
      dra.networking/ifName:
        string: "enp3s0f0v0"
      dra.networking/pfName:
        string: "enp3s0f0"
      dra.networking/vfIndex:
        int: 0
      dra.networking/pciAddress:
        string: "0000:03:00.2"
      dra.networking/numaNode:
        int: 0
      dra.networking/rdma:
        bool: true
      dra.networking/vendor:
        string: "15b3"
      dra.networking/product:
        string: "101e"
      dra.networking/driver:
        string: "mlx5_core"
      dra.networking/supportedCNIs:
        stringSlice:
          - sriov
          - host-device
      device.k8s.io/pcieRoot:
        string: "pci0000:00"
  consumesCounters:
    - counterSet: pf0-counters
      counters:
        exclusion-slots:
          value: 1
```

#### Explanation

- Both plugins are `exclusive: true` → `allowMultipleAllocations` stays
  `false`. The device can be claimed for either `sriov` or `host-device`,
  but not both simultaneously and not by multiple pods.
- `supportedCNIs: ["sriov", "host-device"]` — the NetworkTopology
  controller's auto-injected CEL check (`supportedCNIs.includes("sriov")`)
  ensures the right CNI type is used.
- The choice between `sriov` and `host-device` is made in the
  `NetworkTopology` root step's `type` field, not in the policy.

---

### 5.3 Example 3: PF as Macvlan Parent

**Scenario:** PF `enp3s0f1` is used as a macvlan parent. Multiple pods share
the PF — each gets a macvlan sub-interface. Capacity: 64 macvlans.

#### DeviceExposurePolicy

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf1-macvlan-parent
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "pf" &&
      device.attributes["dra.networking"].ifName == "enp3s0f1"
  action: expose
  exposure:
    allowMultipleAllocations: true
    capacity:
      macvlans:
        value: "64"
        requestPolicy:
          default: "1"
          validRange:
            min: "1"
            max: "4"
            step: "1"
    supportedCNIPlugins:
      - name: macvlan
        exclusive: false
        consumePerAllocation:
          macvlans: 1
```

#### Resulting ResourceSlice Device Entry

```yaml
- name: enp3s0f1
  allowMultipleAllocations: true
  basic:
    attributes:
      dra.networking/type:
        string: "pf"
      dra.networking/ifName:
        string: "enp3s0f1"
      dra.networking/pciAddress:
        string: "0000:03:00.1"
      dra.networking/mac:
        string: "04:3f:72:b0:d4:61"
      dra.networking/mtu:
        int: 1500
      dra.networking/linkSpeed:
        int: 25000
      dra.networking/numaNode:
        int: 0
      dra.networking/supportedCNIs:
        stringSlice:
          - macvlan
      device.k8s.io/pcieRoot:
        string: "pci0000:00"
    capacity:
      dra.networking/macvlans:
        value: "64"
        requestPolicy:
          default: "1"
          validRange:
            min: "1"
            max: "4"
            step: "1"
```

#### Explanation

- `allowMultipleAllocations: true` → the PF can be allocated to multiple
  pods simultaneously. The PF stays on the host.
- `capacity.macvlans: 64` → the scheduler tracks consumption. After 64
  macvlan allocations (each consuming 1), no more allocations are possible.
- The driver doesn't know what a macvlan is. It just sees "this policy says
  publish capacity counter `macvlans` with value 64 and set
  `allowMultipleAllocations: true`." It copies these fields verbatim.
- No shared counter set — this PF has no VFs in this scenario.

---

### 5.4 Example 4: PF with Macvlan AND Ipvlan (Exclusion Group)

**Scenario:** PF `enp3s0f1` supports both `macvlan` and `ipvlan` CNI
plugins. Both create sub-interfaces on the PF. But the kernel's `rx_handler`
allows only one type at a time — if a macvlan is active, ipvlan cannot
be added, and vice versa.

#### Solution: Two Device Entries with Shared Counter

Same pattern as Example 5 (exclusive vs shared). Publish the PF as **two
device entries** — one for macvlan, one for ipvlan — that share a counter
set. Allocating one drains the other's capacity.

#### DeviceExposurePolicy — Macvlan persona

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf1-macvlan
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "pf" &&
      device.attributes["dra.networking"].ifName == "enp3s0f1"
  action: expose
  exposure:
    deviceNameSuffix: "-macvlan"
    exclusionGroup: "rx-handler"       # ← links to pf1-ipvlan
    allowMultipleAllocations: true
    capacity:
      macvlans:
        value: "64"
        requestPolicy:
          default: "1"
          validRange:
            min: "1"
            max: "4"
            step: "1"
    supportedCNIPlugins:
      - name: macvlan
        exclusive: false
        consumePerAllocation:
          macvlans: 1
```

#### DeviceExposurePolicy — Ipvlan persona

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf1-ipvlan
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "pf" &&
      device.attributes["dra.networking"].ifName == "enp3s0f1"
  action: expose
  exposure:
    deviceNameSuffix: "-ipvlan"
    exclusionGroup: "rx-handler"       # ← links to pf1-macvlan
    allowMultipleAllocations: true
    capacity:
      ipvlans:
        value: "64"
        requestPolicy:
          default: "1"
          validRange:
            min: "1"
            max: "4"
            step: "1"
    supportedCNIPlugins:
      - name: ipvlan
        exclusive: false
        consumePerAllocation:
          ipvlans: 1
```

#### Resulting ResourceSlice

```yaml
sharedCounters:
  - name: pf1-rx-handler
    counters:
      macvlan-capacity:
        value: 64
      ipvlan-capacity:
        value: 64

devices:
  # Macvlan persona
  - name: enp3s0f1-macvlan
    allowMultipleAllocations: true
    basic:
      attributes:
        dra.networking/type: { string: "pf" }
        dra.networking/ifName: { string: "enp3s0f1" }
        dra.networking/pciAddress: { string: "0000:03:00.1" }
        dra.networking/linkSpeed: { int: 25000 }
        dra.networking/numaNode: { int: 0 }
        dra.networking/supportedCNIs: { stringSlice: [macvlan] }
        device.k8s.io/pcieRoot: { string: "pci0000:00" }
      capacity:
        dra.networking/macvlans:
          value: "64"
          requestPolicy:
            default: "1"
            validRange: { min: "1", max: "4", step: "1" }
    consumesCounters:
      - counterSet: pf1-rx-handler
        counters:
          ipvlan-capacity: { value: 64 }    # 1st macvlan drains ALL ipvlan

  # Ipvlan persona
  - name: enp3s0f1-ipvlan
    allowMultipleAllocations: true
    basic:
      attributes:
        dra.networking/type: { string: "pf" }
        dra.networking/ifName: { string: "enp3s0f1" }
        dra.networking/pciAddress: { string: "0000:03:00.1" }
        dra.networking/linkSpeed: { int: 25000 }
        dra.networking/numaNode: { int: 0 }
        dra.networking/supportedCNIs: { stringSlice: [ipvlan] }
        device.k8s.io/pcieRoot: { string: "pci0000:00" }
      capacity:
        dra.networking/ipvlans:
          value: "64"
          requestPolicy:
            default: "1"
            validRange: { min: "1", max: "4", step: "1" }
    consumesCounters:
      - counterSet: pf1-rx-handler
        counters:
          macvlan-capacity: { value: 64 }    # 1st ipvlan drains ALL macvlan
```

#### Explanation

The `rx_handler` exclusion is enforced through **two device entries sharing
a counter set**, each draining the other's capacity on first allocation:

- `enp3s0f1-macvlan` has `consumesCounters: ipvlan-capacity: 64`. The
  **first** macvlan allocation drains all ipvlan capacity from the shared
  counter set → the ipvlan device can't allocate (its counter set has 0).
- `enp3s0f1-ipvlan` has `consumesCounters: macvlan-capacity: 64`.
  Symmetrically, the first ipvlan drains all macvlan capacity.
- Subsequent macvlan allocations (2nd, 3rd, ...) do NOT re-consume the
  shared counter — `consumesCounters` is a **static per-device**
  consumption, charged once when the device is first allocated, not
  per-claim. This is the key difference from the broken cross-consumption
  approach (Section 3).

**Walkthrough:**

| Event | macvlan-capacity (shared) | ipvlan-capacity (shared) | macvlan device capacity | ipvlan device capacity |
|---|:---:|:---:|:---:|:---:|
| Initial | 64 | 64 | 64 | 64 |
| 1st macvlan allocated | 64 | **0** (drained by device) | 63 | 64 |
| 2nd macvlan allocated | 64 | 0 | 62 | 64 |
| ipvlan attempted | needs macvlan-capacity=64 → **OK** but ipvlan-capacity=0 → **blocked** | | | |

> Wait — there's a subtlety. `consumesCounters` on a device with
> `allowMultipleAllocations: true` is consumed **per device** (once),
> not **per allocation**. The first allocation of `enp3s0f1-macvlan`
> triggers the device's `consumesCounters`, draining `ipvlan-capacity: 64`.
> All subsequent allocations of the same device don't re-charge the
> shared counter — they only consume from the device's own `capacity`.
>
> This is exactly the "consume once" semantics we need for exclusion
> groups, and it's how DRA's `allowMultipleAllocations` + `consumesCounters`
> already works (KEP 5075).

The admin encodes the kernel `rx_handler` conflict as separate device
personas with cross-draining shared counters. The driver doesn't know
about `rx_handler` — it just follows the two policies.

---

### 5.5 Example 5: PF with Macvlan AND Host-Device Passthrough

**Scenario:** PF `enp3s0f0` supports both `macvlan` (shared, multiple pods)
and `host-device` (exclusive, moves the entire PF into one pod). If
`host-device` is used, all macvlans are blocked, and vice versa.

#### The Problem with a Single Device

You **cannot** put both macvlan and host-device on the same device entry:

- `allowMultipleAllocations: true` is needed for macvlan (shared).
- `allowMultipleAllocations: false` is needed for host-device (exclusive).
- DRA's `allowMultipleAllocations` is device-wide — it can't be
  per-allocation-type.

Even if we set `allowMultipleAllocations: true` and tried to use capacity
to block host-device after macvlan (or vice versa), the scheduler has no
mechanism to consume "all remaining capacity" for one allocation type while
consuming "1" for another type on the same device.

#### Solution: Two Device Entries with Shared Counters

The driver publishes the **same physical PF** as **two device entries**
that share a counter set for mutual exclusion:

1. `enp3s0f0-macvlan` — multi-allocatable, capacity `macvlans: 64`,
   supportedCNIs: `[macvlan]`
2. `enp3s0f0-passthrough` — exclusive (normal device),
   supportedCNIs: `[host-device]`

Both consume from the same shared counter set. The passthrough device
consumes ALL counters, blocking macvlans.

#### DeviceExposurePolicy — Macvlan Parent

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf0-macvlan
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "pf" &&
      device.attributes["dra.networking"].ifName == "enp3s0f0"
  action: expose
  exposure:
    # This policy creates the macvlan persona of the PF
    deviceNameSuffix: "-macvlan"
    allowMultipleAllocations: true
    capacity:
      macvlans:
        value: "64"
        requestPolicy:
          default: "1"
          validRange:
            min: "1"
            max: "4"
            step: "1"
    supportedCNIPlugins:
      - name: macvlan
        exclusive: false
        consumePerAllocation:
          macvlans: 1
```

#### DeviceExposurePolicy — PF Passthrough

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf0-passthrough
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "pf" &&
      device.attributes["dra.networking"].ifName == "enp3s0f0"
  action: expose
  exposure:
    # This policy creates the passthrough persona of the PF
    deviceNameSuffix: "-passthrough"
    allowMultipleAllocations: false
    supportedCNIPlugins:
      - name: host-device
        exclusive: true
```

#### Key CRD Addition: `deviceNameSuffix`

When **multiple expose policies** match the same physical device, the
driver creates **one device entry per policy** with a suffixed name.
This is necessary because a single physical interface can serve multiple
roles (macvlan parent vs passthrough), each with different DRA semantics.

The `deviceNameSuffix` field tells the driver: "publish this as
`<interfaceName><suffix>`." If omitted, the device uses its raw
interface name (only valid when one policy matches).

#### Resulting ResourceSlice

```yaml
sharedCounters:
  - name: pf0-counters
    counters:
      macvlan-capacity:
        value: 64

devices:
  # Macvlan persona: multi-alloc, capacity-tracked
  - name: enp3s0f0-macvlan
    allowMultipleAllocations: true
    basic:
      attributes:
        dra.networking/type: { string: "pf" }
        dra.networking/ifName: { string: "enp3s0f0" }
        dra.networking/pciAddress: { string: "0000:03:00.0" }
        dra.networking/linkSpeed: { int: 100000 }
        dra.networking/numaNode: { int: 0 }
        dra.networking/supportedCNIs: { stringSlice: [macvlan] }
        device.k8s.io/pcieRoot: { string: "pci0000:00" }
      capacity:
        dra.networking/macvlans:
          value: "64"
          requestPolicy:
            default: "1"
            validRange: { min: "1", max: "4", step: "1" }
    consumesCounters:
      - counterSet: pf0-counters
        counters:
          macvlan-capacity: { value: 0 }  # per-alloc consumption tracked via device capacity

  # Passthrough persona: exclusive, drains all shared counters
  - name: enp3s0f0-passthrough
    basic:
      attributes:
        dra.networking/type: { string: "pf" }
        dra.networking/ifName: { string: "enp3s0f0" }
        dra.networking/pciAddress: { string: "0000:03:00.0" }
        dra.networking/linkSpeed: { int: 100000 }
        dra.networking/numaNode: { int: 0 }
        dra.networking/supportedCNIs: { stringSlice: [host-device] }
        device.k8s.io/pcieRoot: { string: "pci0000:00" }
    consumesCounters:
      - counterSet: pf0-counters
        counters:
          macvlan-capacity: { value: 64 }  # consumes ALL → blocks all macvlans
```

#### Explanation

- **Two device entries, one physical interface.** The driver creates both
  from the two matching policies (distinguished by `deviceNameSuffix`).
- **Mutual exclusion via shared counter `macvlan-capacity: 64`:**
  - Macvlan allocations consume from the device's own `capacity.macvlans`
    (tracked by the scheduler's consumable capacity logic).
  - PF passthrough consumes `macvlan-capacity: 64` from the shared counter
    → no macvlan capacity remains → macvlan device is fully consumed.
  - Conversely, if any macvlan is allocated, the shared counter has
    < 64 available → passthrough can't get all 64 → blocked.
- **No `allowMultipleAllocations` mixing.** The macvlan device is
  multi-alloc. The passthrough device is exclusive. Clean separation.
- **Same physical PF attributes** on both entries (PCI address, NUMA,
  etc.) — `matchAttribute` constraints still work for GPU co-location.

---

### 5.6 Example 6: PF with VFs + Macvlan + Host-Device

**Scenario:** The most complex case. PF `enp3s0f0` has 8 VFs and also
serves as a macvlan parent. The PF can also be passthrough'd via
`host-device`, which blocks **both** VFs and macvlans.

This requires **three** policies — macvlan persona, passthrough persona,
and VFs. The PF appears as two device entries (same pattern as Example 5).

#### DeviceExposurePolicy — PF as macvlan parent

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf0-macvlan
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "pf" &&
      device.attributes["dra.networking"].ifName == "enp3s0f0"
  action: expose
  exposure:
    deviceNameSuffix: "-macvlan"
    allowMultipleAllocations: true
    capacity:
      macvlans:
        value: "64"
        requestPolicy:
          default: "1"
          validRange:
            min: "1"
            max: "4"
            step: "1"
    supportedCNIPlugins:
      - name: macvlan
        exclusive: false
        consumePerAllocation:
          macvlans: 1
```

#### DeviceExposurePolicy — PF as passthrough

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf0-passthrough
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "pf" &&
      device.attributes["dra.networking"].ifName == "enp3s0f0"
  action: expose
  exposure:
    deviceNameSuffix: "-passthrough"
    allowMultipleAllocations: false
    supportedCNIPlugins:
      - name: host-device
        exclusive: true
```

#### DeviceExposurePolicy — VFs

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf0-vfs
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "vf" &&
      device.attributes["dra.networking"].pfName == "enp3s0f0"
  action: expose
  exposure:
    allowMultipleAllocations: false
    supportedCNIPlugins:
      - name: sriov
        exclusive: true
      - name: host-device
        exclusive: true
```

#### Resulting ResourceSlice (PF personas + VFs in the same pool)

```yaml
sharedCounters:
  - name: pf0-counters
    counters:
      exclusion-slots:
        value: 9               # 8 VFs + 1 (automatic from PF/VF relationship)
      bandwidth:
        value: 100000          # 100 Gbps (from PF linkSpeed)
        requestPolicy:
          default: 12500
          validRange:
            min: 100
            max: 100000
            step: 100
      macvlan-capacity:
        value: 64              # from PF macvlan policy's capacity

devices:
  # ── PF macvlan persona: multi-allocatable ──
  - name: enp3s0f0-macvlan
    allowMultipleAllocations: true
    basic:
      attributes:
        dra.networking/type: { string: "pf" }
        dra.networking/ifName: { string: "enp3s0f0" }
        dra.networking/pciAddress: { string: "0000:03:00.0" }
        dra.networking/linkSpeed: { int: 100000 }
        dra.networking/numVFs: { int: 8 }
        dra.networking/rdma: { bool: true }
        dra.networking/numaNode: { int: 0 }
        dra.networking/supportedCNIs: { stringSlice: [macvlan] }
        device.k8s.io/pcieRoot: { string: "pci0000:00" }
      capacity:
        dra.networking/macvlans:
          value: "64"
          requestPolicy:
            default: "1"
            validRange: { min: "1", max: "4", step: "1" }

  # ── PF passthrough persona: exclusive, drains everything ──
  - name: enp3s0f0-passthrough
    basic:
      attributes:
        dra.networking/type: { string: "pf" }
        dra.networking/ifName: { string: "enp3s0f0" }
        dra.networking/pciAddress: { string: "0000:03:00.0" }
        dra.networking/linkSpeed: { int: 100000 }
        dra.networking/numVFs: { int: 8 }
        dra.networking/rdma: { bool: true }
        dra.networking/numaNode: { int: 0 }
        dra.networking/supportedCNIs: { stringSlice: [host-device] }
        device.k8s.io/pcieRoot: { string: "pci0000:00" }
    consumesCounters:
      - counterSet: pf0-counters
        counters:
          exclusion-slots: { value: 9 }       # blocks all VFs
          bandwidth: { value: 100000 }         # takes all bandwidth
          macvlan-capacity: { value: 64 }      # blocks all macvlans

  # ── VF 0: exclusive ──
  - name: enp3s0f0v0
    basic:
      attributes:
        dra.networking/type:
          string: "vf"
        dra.networking/ifName:
          string: "enp3s0f0v0"
        dra.networking/pfName:
          string: "enp3s0f0"
        dra.networking/vfIndex:
          int: 0
        dra.networking/pciAddress:
          string: "0000:03:00.2"
        dra.networking/rdma:
          bool: true
        dra.networking/numaNode:
          int: 0
        dra.networking/supportedCNIs:
          stringSlice:
            - sriov
            - host-device
        device.k8s.io/pcieRoot:
          string: "pci0000:00"
    consumesCounters:
      - counterSet: pf0-counters
        counters:
          exclusion-slots:
            value: 1
          bandwidth:
            valueFrom:
              capacityKey: "dra.networking/bandwidth"

  # ── VFs 1–7 follow the same pattern ──
```

#### Explanation

The PF is published as **two device entries** (macvlan persona + passthrough
persona), plus the 8 VFs. All share one counter set (`pf0-counters`):

| Counter | Purpose | PF-passthrough consumption | VF consumption | Macvlan consumption |
|---|---|---|---|---|
| `exclusion-slots` | PF/VF mutual exclusion | 9 (all) | 1 | 0 |
| `bandwidth` | Shared link bandwidth | 100000 (all) | `valueFrom` (per-claim) | 0 |
| `macvlan-capacity` | Macvlan slot limit | 64 (all) | 0 | 1 (via device capacity) |

- **PF passthrough** (`enp3s0f0-passthrough`, exclusive device) consumes
  ALL of everything → blocks VFs and macvlans.
- **VF allocation** consumes 1 exclusion-slot + some bandwidth → eventually
  blocks PF passthrough, never blocks macvlans.
- **Macvlan allocation** (`enp3s0f0-macvlan`, multi-alloc device) consumes
  1 macvlan from the device's capacity → eventually exhausts macvlan
  slots, but passthrough can't consume 64 if any macvlan is active.
- **VFs and macvlans coexist** — they consume from independent counters
  (`exclusion-slots` vs `macvlan-capacity`). Allocating VFs doesn't block
  macvlans and vice versa.

> **Key principle:** Never mix `allowMultipleAllocations: true` (shared)
> and exclusive semantics on a single device entry. Use separate device
> entries with shared counters for mutual exclusion.

---

### 5.7 Example 7: VF as Bridge Port OR SR-IOV

**Scenario:** A VF can be used in two ways: (a) `sriov` moves it to a pod
(exclusive), or (b) `bridge` — the VF is pre-enslaved to a host bridge,
and bridge-cni creates a veth pair to that bridge (the bridge is shared,
multiple pods connect).

This is a special case because the VF's role depends on host-side
preconfiguration. If the VF is enslaved to a bridge, it acts as a shared
uplink. If it's free, it's an exclusive SR-IOV device.

#### DeviceExposurePolicy — Free VFs (for sriov)

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: free-vfs-sriov
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "vf" &&
      device.attributes["dra.networking"].pfName == "enp3s0f0" &&
      device.attributes["dra.networking"].masterBridge == ""
  action: expose
  exposure:
    allowMultipleAllocations: false
    supportedCNIPlugins:
      - name: sriov
        exclusive: true
      - name: host-device
        exclusive: true
```

#### DeviceExposurePolicy — Bridge-Slave VFs (hidden; bridge exposed instead)

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: exclude-bridge-slave-vfs
spec:
  priority: 900
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "vf" &&
      device.attributes["dra.networking"].masterBridge != ""
  action: exclude
```

#### DeviceExposurePolicy — The Bridge the VF is enslaved to

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: bridge-sriov-data
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "bridge" &&
      device.attributes["dra.networking"].ifName == "br-sriov-data"
  action: expose
  exposure:
    allowMultipleAllocations: true
    capacity:
      ports:
        value: "64"
        requestPolicy:
          default: "1"
          validRange:
            min: "1"
            max: "4"
            step: "1"
    supportedCNIPlugins:
      - name: bridge
        exclusive: false
        consumePerAllocation:
          ports: 1
```

#### Resulting ResourceSlice Entries

Free VFs are published as exclusive devices (same as Example 1). The
bridge-slave VF is hidden. The bridge is published as shared:

```yaml
- name: br-sriov-data
  allowMultipleAllocations: true
  basic:
    attributes:
      dra.networking/type:
        string: "bridge"
      dra.networking/ifName:
        string: "br-sriov-data"
      dra.networking/bridgeName:
        string: "br-sriov-data"
      dra.networking/bridgeType:
        string: "linux"
      dra.networking/mtu:
        int: 9000
      dra.networking/supportedCNIs:
        stringSlice:
          - bridge
    capacity:
      dra.networking/ports:
        value: "64"
        requestPolicy:
          default: "1"
          validRange:
            min: "1"
            max: "4"
            step: "1"
```

#### Explanation

- The driver discovers the VF's `masterBridge` attribute by reading
  `/sys/class/net/enp3s0f0v0/master`. It publishes this raw fact.
- The admin's `exclude-bridge-slave-vfs` policy hides any VF that has a
  non-empty `masterBridge`.
- The bridge itself is the allocatable device. Pods get veth pairs to it.
- The enslaved VF still consumes 1 `exclusion-slot` in the PF's counter
  set (the driver reduces the counter's effective available value to
  account for pre-enslaved VFs).

---

### 5.8 Example 8: Excluding Cluster CNI Interfaces

**Scenario:** OVN-Kubernetes and management interfaces must never be
exposed to workloads.

#### DeviceExposurePolicy — Exclude OVN-K

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: exclude-ovn-k
spec:
  priority: 1000
  selector:
    cel: >-
      device.attributes["dra.networking"].ifName in
      ["br-int", "ovn-k8s-mp0", "breth0", "ovn-k8s-gw0"]
  action: exclude
```

#### DeviceExposurePolicy — Exclude Management

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: exclude-management
spec:
  priority: 1000
  selector:
    cel: >-
      device.attributes["dra.networking"].ifName == "eno1"
  action: exclude
```

#### Resulting ResourceSlice

These devices are simply absent. The driver discovers `br-int`, evaluates
all policies, finds the `exclude-ovn-k` policy matches with
`action: exclude`, and skips the device. Same for `eno1`.

No ResourceSlice entry is published for excluded devices.

#### Explanation

- `priority: 1000` is conventionally the highest. But the exact value
  doesn't matter for exclusions — `action: exclude` **always wins**
  regardless of priority. Even a `priority: 1` exclusion overrides a
  `priority: 1000` expose policy.
- The driver doesn't know that `br-int` is an OVN-K bridge. It just sees
  an interface named `br-int`, evaluates the CEL selector, and follows
  the policy's `action: exclude` instruction.

---

### 5.9 Example 9: OVN-Kubernetes Networks via Our Generic Driver

**Scenario:** OVN-Kubernetes uses `ovn-k8s-cni-overlay` as its CNI binary
for all network types (UDN layer2/layer3, localnet). Our generic driver
can serve OVN-K use cases directly — no separate OVN-K DRA driver needed.
The admin creates DeviceExposurePolicies that list `ovn-k8s-cni-overlay`
as a supported CNI plugin.

#### DeviceExposurePolicy — Switchdev VFs for OVN-K accelerated UDN

OVN-K CNI runtime config (`topology`, `role`, `netAttachDefName`,
`subnets`, `vlanID`) belongs in the **NetworkTopology step's `config`
block** — that's the CNI JSON passed to `ovn-k8s-cni-overlay` at
invocation time (see the chainable networking proposal section 9b).

The `DeviceExposurePolicy.additionalAttributes` should only add
attributes needed for **device selection** at scheduling time — e.g.
`physicalNetworkName` for localnet, so a DeviceClass CEL selector can
match the right uplink.

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: ovnk-accelerated-vfs
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "vf" &&
      device.attributes["dra.networking"].pfName == "enp4s0f0"
  action: expose
  exposure:
    supportedCNIPlugins:
      - name: ovn-k8s-cni-overlay
        exclusive: true
```

No `additionalAttributes` needed for accelerated VFs — the driver
already discovers PCI address, NUMA, pcieRoot, etc. The OVN-K CNI
config (`topology: layer2`, `role: secondary`, `subnets`, etc.) is
declared in the NetworkTopology step's `config`, not here.

#### DeviceExposurePolicy — PF as localnet uplink (shared)

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: ovnk-localnet-uplink
spec:
  priority: 150
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "pf" &&
      device.attributes["dra.networking"].ifName == "enp6s0f0"
  action: expose
  exposure:
    deviceNameSuffix: "-localnet"
    allowMultipleAllocations: true
    capacity:
      connections:
        value: "128"
        requestPolicy:
          default: "1"
    supportedCNIPlugins:
      - name: ovn-k8s-cni-overlay
        exclusive: false
        consumePerAllocation:
          connections: 1
    # Only attributes needed for device SELECTION go here.
    # OVN-K runtime config (topology, role, subnets, vlanID) goes
    # in the NetworkTopology step's config block instead.
    additionalAttributes:
      "dra.networking/physicalNetworkName": "localnet1"
```

#### Resulting ResourceSlice Entries

```yaml
# Switchdev VF for OVN-K accelerated UDN (exclusive)
- name: enp4s0f0v0
  basic:
    attributes:
      # Discovered by driver (raw hardware facts)
      dra.networking/type: { string: "vf" }
      dra.networking/ifName: { string: "enp4s0f0v0" }
      dra.networking/pfName: { string: "enp4s0f0" }
      dra.networking/pciAddress: { string: "0000:04:00.2" }
      dra.networking/numaNode: { int: 0 }
      device.k8s.io/pcieRoot: { string: "pci0000:00" }
      # From DeviceExposurePolicy
      dra.networking/supportedCNIs: { stringSlice: [ovn-k8s-cni-overlay] }

# Localnet uplink (shared, multi-alloc)
- name: enp6s0f0-localnet
  allowMultipleAllocations: true
  basic:
    attributes:
      # Discovered by driver
      dra.networking/type: { string: "pf" }
      dra.networking/ifName: { string: "enp6s0f0" }
      dra.networking/numaNode: { int: 1 }
      device.k8s.io/pcieRoot: { string: "pci0000:00" }
      # From DeviceExposurePolicy
      dra.networking/supportedCNIs: { stringSlice: [ovn-k8s-cni-overlay] }
      dra.networking/physicalNetworkName: { string: "localnet1" }
    capacity:
      dra.networking/connections:
        value: "128"
        requestPolicy:
          default: "1"
```

#### Explanation

- **Our generic driver handles OVN-K devices.** The driver discovers
  switchdev VFs and PFs like any other device. The `DeviceExposurePolicy`
  lists `ovn-k8s-cni-overlay` as the supported CNI — our driver invokes
  it during the NRI hook's CNI chain just like `sriov` or `bond`.
- **UDN accelerated VFs** are exclusive (one pod per VF). The
  `ovn-k8s-cni-overlay` CNI configures the VF representor on `br-int`,
  programs OVN logical ports, and moves the VF to the pod.
- **Localnet uplink** is shared (`allowMultipleAllocations: true`). Each
  pod gets a veth pair via OVN-K's CNI. The PF stays on the host.
  Capacity tracks concurrent connections.
- **Chaining works:** a NetworkTopology root step with
  `type: ovn-k8s-cni-overlay` can have derived steps (tuning, etc.)
  chained on top — see the chainable networking proposal section 9b.

---

## 6. Complete Reference Node

### 6.1 Node Inventory

Node `worker-1`:

| Device | Interface | Type | PCI Address | Speed | NUMA | Notes |
|---|---|---|---|---|---|---|
| PF 0 | `enp3s0f0` | Physical Function | `0000:03:00.0` | 100 GbE | 0 | ConnectX-7, 8 VFs, RDMA, macvlan parent |
| PF 1 | `enp3s0f1` | Physical Function | `0000:03:00.1` | 25 GbE | 0 | ConnectX-7, 4 VFs, RDMA |
| VF 0–7 of PF 0 | `enp3s0f0v0`–`v7` | Virtual Function | `0000:03:00.2`–`0000:03:01.1` | — | 0 | SR-IOV |
| VF 0–3 of PF 1 | `enp3s0f1v0`–`v3` | Virtual Function | `0000:03:01.2`–`0000:03:01.5` | — | 0 | SR-IOV |
| Bridge | `br-data` | Linux bridge | — | — | — | VLAN filtering, MTU 9000 |
| Management | `eno1` | Regular NIC | — | 1 GbE | — | SSH/BMC |
| OVN-K | `br-int` | OVS bridge | — | — | — | Cluster CNI |
| OVN-K | `ovn-k8s-mp0` | Virtual | — | — | — | Cluster CNI |

### 6.2 Complete DeviceExposurePolicy Set

```yaml
# 1. Exclude cluster CNI infrastructure
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: exclude-cluster-cni
spec:
  priority: 1000
  selector:
    cel: >-
      device.attributes["dra.networking"].ifName in
      ["br-int", "ovn-k8s-mp0", "breth0", "ovn-k8s-gw0"]
  action: exclude
---
# 2. Exclude management interface
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: exclude-management
spec:
  priority: 1000
  selector:
    cel: >-
      device.attributes["dra.networking"].ifName == "eno1"
  action: exclude
---
# 3. PF0 macvlan persona (shared)
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf0-macvlan
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "pf" &&
      device.attributes["dra.networking"].ifName == "enp3s0f0"
  action: expose
  exposure:
    deviceNameSuffix: "-macvlan"
    allowMultipleAllocations: true
    capacity:
      macvlans:
        value: "64"
        requestPolicy:
          default: "1"
          validRange:
            min: "1"
            max: "4"
            step: "1"
    supportedCNIPlugins:
      - name: macvlan
        exclusive: false
        consumePerAllocation:
          macvlans: 1
---
# 4. PF0 passthrough persona (exclusive)
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf0-passthrough
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "pf" &&
      device.attributes["dra.networking"].ifName == "enp3s0f0"
  action: expose
  exposure:
    deviceNameSuffix: "-passthrough"
    allowMultipleAllocations: false
    supportedCNIPlugins:
      - name: host-device
        exclusive: true
---
# 5. PF0 VFs: sriov + host-device (both exclusive → single device entry)
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf0-vfs
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "vf" &&
      device.attributes["dra.networking"].pfName == "enp3s0f0"
  action: expose
  exposure:
    allowMultipleAllocations: false
    supportedCNIPlugins:
      - name: sriov
        exclusive: true
      - name: host-device
        exclusive: true
---
# 6. PF1: host-device passthrough only
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf1-passthrough
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "pf" &&
      device.attributes["dra.networking"].ifName == "enp3s0f1"
  action: expose
  exposure:
    allowMultipleAllocations: false
    supportedCNIPlugins:
      - name: host-device
        exclusive: true
---
# 7. PF1 VFs: sriov + host-device
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: pf1-vfs
spec:
  priority: 200
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "vf" &&
      device.attributes["dra.networking"].pfName == "enp3s0f1"
  action: expose
  exposure:
    allowMultipleAllocations: false
    supportedCNIPlugins:
      - name: sriov
        exclusive: true
      - name: host-device
        exclusive: true
---
# 8. Bridge br-data
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: bridge-br-data
spec:
  priority: 150
  selector:
    cel: >-
      device.attributes["dra.networking"].type == "bridge" &&
      device.attributes["dra.networking"].ifName == "br-data"
  action: expose
  exposure:
    allowMultipleAllocations: true
    capacity:
      ports:
        value: "64"
        requestPolicy:
          default: "1"
          validRange:
            min: "1"
            max: "4"
            step: "1"
    supportedCNIPlugins:
      - name: bridge
        exclusive: false
        consumePerAllocation:
          ports: 1
```

### 6.3 Resulting ResourceSlices

#### ResourceSlice 1: PF0 Pool (PF + 8 VFs)

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceSlice
metadata:
  name: worker-1-sriov-pf0
spec:
  driver: dra.networking
  pool:
    name: worker-1-sriov-pf0
    generation: 1
    resourceSliceCount: 1
  nodeName: worker-1

  sharedCounters:
    - name: pf0-counters
      counters:
        exclusion-slots:
          value: 9
        bandwidth:
          value: 100000
          requestPolicy:
            default: 12500
            validRange:
              min: 100
              max: 100000
              step: 100
        macvlan-capacity:
          value: 64

  devices:
    # PF macvlan persona (from pf0-macvlan policy)
    - name: enp3s0f0-macvlan
      allowMultipleAllocations: true
      basic:
        attributes:
          dra.networking/type: { string: "pf" }
          dra.networking/ifName: { string: "enp3s0f0" }
          dra.networking/pciAddress: { string: "0000:03:00.0" }
          dra.networking/mac: { string: "04:3f:72:b0:d4:60" }
          dra.networking/mtu: { int: 1500 }
          dra.networking/linkSpeed: { int: 100000 }
          dra.networking/rdma: { bool: true }
          dra.networking/numaNode: { int: 0 }
          dra.networking/supportedCNIs: { stringSlice: [macvlan] }
          device.k8s.io/pcieRoot: { string: "pci0000:00" }
        capacity:
          dra.networking/macvlans:
            value: "64"
            requestPolicy:
              default: "1"
              validRange: { min: "1", max: "4", step: "1" }

    # PF passthrough persona (from pf0-passthrough policy)
    - name: enp3s0f0-passthrough
      basic:
        attributes:
          dra.networking/type: { string: "pf" }
          dra.networking/ifName: { string: "enp3s0f0" }
          dra.networking/pciAddress: { string: "0000:03:00.0" }
          dra.networking/linkSpeed: { int: 100000 }
          dra.networking/rdma: { bool: true }
          dra.networking/numaNode: { int: 0 }
          dra.networking/supportedCNIs: { stringSlice: [host-device] }
          device.k8s.io/pcieRoot: { string: "pci0000:00" }
      consumesCounters:
        - counterSet: pf0-counters
          counters:
            exclusion-slots: { value: 9 }
            bandwidth: { value: 100000 }
            macvlan-capacity: { value: 64 }

    - name: enp3s0f0v0
      basic:
        attributes:
          dra.networking/type: { string: "vf" }
          dra.networking/ifName: { string: "enp3s0f0v0" }
          dra.networking/pfName: { string: "enp3s0f0" }
          dra.networking/vfIndex: { int: 0 }
          dra.networking/pciAddress: { string: "0000:03:00.2" }
          dra.networking/rdma: { bool: true }
          dra.networking/vendor: { string: "15b3" }
          dra.networking/product: { string: "101e" }
          dra.networking/driver: { string: "mlx5_core" }
          dra.networking/numaNode: { int: 0 }
          dra.networking/supportedCNIs: { stringSlice: [sriov, host-device] }
          device.k8s.io/pcieRoot: { string: "pci0000:00" }
      consumesCounters:
        - counterSet: pf0-counters
          counters:
            exclusion-slots: { value: 1 }
            bandwidth:
              valueFrom: { capacityKey: "dra.networking/bandwidth" }

    # VFs 1–6 identical pattern (omitted)

    - name: enp3s0f0v7
      basic:
        attributes:
          dra.networking/type: { string: "vf" }
          dra.networking/ifName: { string: "enp3s0f0v7" }
          dra.networking/pfName: { string: "enp3s0f0" }
          dra.networking/vfIndex: { int: 7 }
          dra.networking/pciAddress: { string: "0000:03:01.1" }
          dra.networking/rdma: { bool: true }
          dra.networking/vendor: { string: "15b3" }
          dra.networking/product: { string: "101e" }
          dra.networking/driver: { string: "mlx5_core" }
          dra.networking/numaNode: { int: 0 }
          dra.networking/supportedCNIs: { stringSlice: [sriov, host-device] }
          device.k8s.io/pcieRoot: { string: "pci0000:00" }
      consumesCounters:
        - counterSet: pf0-counters
          counters:
            exclusion-slots: { value: 1 }
            bandwidth:
              valueFrom: { capacityKey: "dra.networking/bandwidth" }
```

#### ResourceSlice 2: PF1 Pool (PF + 4 VFs)

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceSlice
metadata:
  name: worker-1-sriov-pf1
spec:
  driver: dra.networking
  pool:
    name: worker-1-sriov-pf1
    generation: 1
    resourceSliceCount: 1
  nodeName: worker-1

  sharedCounters:
    - name: pf1-counters
      counters:
        exclusion-slots:
          value: 5
        bandwidth:
          value: 25000
          requestPolicy:
            default: 6250
            validRange: { min: 100, max: 25000, step: 100 }

  devices:
    - name: enp3s0f1
      basic:
        attributes:
          dra.networking/type: { string: "pf" }
          dra.networking/ifName: { string: "enp3s0f1" }
          dra.networking/pciAddress: { string: "0000:03:00.1" }
          dra.networking/mac: { string: "04:3f:72:b0:d4:61" }
          dra.networking/mtu: { int: 1500 }
          dra.networking/linkSpeed: { int: 25000 }
          dra.networking/rdma: { bool: true }
          dra.networking/numVFs: { int: 4 }
          dra.networking/vendor: { string: "15b3" }
          dra.networking/product: { string: "101d" }
          dra.networking/driver: { string: "mlx5_core" }
          dra.networking/numaNode: { int: 0 }
          dra.networking/supportedCNIs: { stringSlice: [host-device] }
          device.k8s.io/pcieRoot: { string: "pci0000:00" }
      consumesCounters:
        - counterSet: pf1-counters
          counters:
            exclusion-slots: { value: 5 }
            bandwidth: { value: 25000 }

    - name: enp3s0f1v0
      basic:
        attributes:
          dra.networking/type: { string: "vf" }
          dra.networking/ifName: { string: "enp3s0f1v0" }
          dra.networking/pfName: { string: "enp3s0f1" }
          dra.networking/vfIndex: { int: 0 }
          dra.networking/pciAddress: { string: "0000:03:01.2" }
          dra.networking/rdma: { bool: true }
          dra.networking/vendor: { string: "15b3" }
          dra.networking/product: { string: "101e" }
          dra.networking/driver: { string: "mlx5_core" }
          dra.networking/numaNode: { int: 0 }
          dra.networking/supportedCNIs: { stringSlice: [sriov, host-device] }
          device.k8s.io/pcieRoot: { string: "pci0000:00" }
      consumesCounters:
        - counterSet: pf1-counters
          counters:
            exclusion-slots: { value: 1 }
            bandwidth:
              valueFrom: { capacityKey: "dra.networking/bandwidth" }

    # VFs 1–2 identical pattern (omitted)

    - name: enp3s0f1v3
      basic:
        attributes:
          dra.networking/type: { string: "vf" }
          dra.networking/ifName: { string: "enp3s0f1v3" }
          dra.networking/pfName: { string: "enp3s0f1" }
          dra.networking/vfIndex: { int: 3 }
          dra.networking/pciAddress: { string: "0000:03:01.5" }
          dra.networking/rdma: { bool: true }
          dra.networking/vendor: { string: "15b3" }
          dra.networking/product: { string: "101e" }
          dra.networking/driver: { string: "mlx5_core" }
          dra.networking/numaNode: { int: 0 }
          dra.networking/supportedCNIs: { stringSlice: [sriov, host-device] }
          device.k8s.io/pcieRoot: { string: "pci0000:00" }
      consumesCounters:
        - counterSet: pf1-counters
          counters:
            exclusion-slots: { value: 1 }
            bandwidth:
              valueFrom: { capacityKey: "dra.networking/bandwidth" }
```

#### ResourceSlice 3: Bridge br-data

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceSlice
metadata:
  name: worker-1-bridge-br-data
spec:
  driver: dra.networking
  pool:
    name: worker-1-bridge-br-data
    generation: 1
    resourceSliceCount: 1
  nodeName: worker-1

  devices:
    - name: br-data
      allowMultipleAllocations: true
      basic:
        attributes:
          dra.networking/type: { string: "bridge" }
          dra.networking/ifName: { string: "br-data" }
          dra.networking/bridgeName: { string: "br-data" }
          dra.networking/bridgeType: { string: "linux" }
          dra.networking/mtu: { int: 9000 }
          dra.networking/vlanFiltering: { bool: true }
          dra.networking/supportedCNIs: { stringSlice: [bridge] }
        capacity:
          dra.networking/ports:
            value: "64"
            requestPolicy:
              default: "1"
              validRange: { min: "1", max: "4", step: "1" }
```

### 6.4 Summary

| ResourceSlice | Pool | Devices | SharedCounters |
|---|---|---|---|
| `worker-1-sriov-pf0` | `worker-1-sriov-pf0` | 2 PF personas + 8 VFs = 10 | exclusion-slots: 9, bandwidth: 100000, macvlan-capacity: 64 |
| `worker-1-sriov-pf1` | `worker-1-sriov-pf1` | 1 PF + 4 VFs = 5 | exclusion-slots: 5, bandwidth: 25000 |
| `worker-1-bridge-br-data` | `worker-1-bridge-br-data` | 1 bridge (multi-alloc) | None |

**Not published:** `eno1`, `br-int`, `ovn-k8s-mp0` (excluded by policy).

Total: 3 ResourceSlice objects, 16 device entries (8 policies).

### 6.5 App Developer Experience

All the complexity above is invisible to the application developer. The
app developer's interaction is minimal — they reference DeviceClass names
in their ResourceClaim and the scheduler handles the rest.

See the [DRA Chainable Networking Proposal](dra-chainable-networking-proposal.md)
for the full user-facing workflow. The summary:

1. **Platform admin** creates `NetworkTopology` + `DeviceExposurePolicy` CRDs.
2. **Controller** generates DeviceClasses (one per root step) with
   `networkTopologyRef` and `supportedCNIs.includes()` CEL baked in.
3. **App developer** writes a ResourceClaim referencing the DeviceClass names:

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: my-app-network
spec:
  spec:
    devices:
      requests:
        - name: vf0
          exactly:
            deviceClassName: ai-bonded-rdma-vf0
        - name: vf1
          exactly:
            deviceClassName: ai-bonded-rdma-vf1
```

No opaque config. No topology references. No knowledge of bonds, VLANs,
macvlans, or capacity counters. The DeviceClass names are the only
interface between the platform team and the app developer.

---

## 7. Open Questions

| # | Question | Notes |
|---|---|---|
| 1 | **Exclusion group scheduling-time enforcement.** Can DRA's capacity model support "consume once per type" semantics? | Current DRA capacity is strictly per-allocation. Without "first-allocation lock" support, exclusion groups require either admin-separated policies or driver-side rejection. See Section 3. |
| 2 | **Dynamic VF count changes.** How should the driver handle `numVFs` changes at runtime? | Must atomically update the counter set and device list. Generation bump triggers scheduler re-evaluation. Must never remove in-use devices. |
| 3 | **Macvlan capacity discovery.** How does the driver determine the maximum macvlan count? | The driver doesn't — the admin specifies it in the policy's `exposure.capacity.macvlans.value`. The driver copies it verbatim. This is consistent with the "driver is generic" principle. |
| 4 | **`requestPolicy.default` with no capacity request.** Does a claim without `capacity.requests` trigger default consumption? | Per KEP 5941 design, yes. Verify with upstream implementation. |
| 5 | **PF macvlan + VF allocation interaction.** Can macvlans and VFs coexist on the same PF? | Generally yes (different kernel paths). The current design models them as independent capacity dimensions in the same counter set. Macvlan allocations don't consume exclusion-slots; VF allocations don't consume macvlan-capacity. |
| 6 | **`allowMultipleAllocations` identity.** All allocations of a multi-allocatable device share the same device name. How to distinguish them? | The `AllocationResult` contains the claim UID. May need enhancement for debugging. |
| 7 | **Cross-pool shared counters.** Can a device in one pool consume counters from another pool? | KEP 4815 scopes counters to a pool. The current design avoids cross-pool counters by putting PF + VFs + macvlan capacity in a single pool. |
| 8 | **Bridge auto-creation.** Should the driver create bridges, or only discover pre-existing ones? | Discovery-only initially. Auto-creation needs coordination with host networking (NetworkManager, systemd-networkd). |
| 9 | **`DRAListTypeAttributes` fallback.** `stringSlice` is alpha (KEP 5491, K8s 1.36). What is the fallback? | Comma-separated string with `contains()`. Works with GA API. Substring collision risk is low for known CNI names but not zero. |
| 10 | **Policy validation webhook.** Should the driver validate that `consumePerAllocation` entries match `capacity` keys? | Yes. A validating webhook should reject policies where `consumePerAllocation` references a counter not defined in `capacity`, or where `exclusive: true` plugins coexist with `allowMultipleAllocations: false` and no capacity. |
