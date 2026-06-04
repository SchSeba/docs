# DRA Chainable Networking

A proposal for declarative, composable network configuration in Kubernetes
using DRA device requests with `dependOn` chaining — enabling bonding, VLANs,
tuning, and mixed NIC + GPU topologies in a single `ResourceClaim`.

**Constraint: this proposal uses only the existing DRA API (DeviceClass,
ResourceClaim, ResourceSlice, opaque config).  No upstream API extensions are
required.**

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [The NetworkTopology CRD](#2-the-networktopology-crd)
   - [Parameterized Config](#23-parameterized-config--referencing-cni-results)
3. [Step Result Model (inspired by CNI)](#3-step-result-model-inspired-by-cni)
4. [From NetworkTopology to DRA Objects](#4-from-networktopology-to-dra-objects)
5. [DeviceClass Design for Mixed NICs + GPUs](#5-deviceclass-design-for-mixed-nics--gpus)
6. [Full Example: 2 VFs + Bond + 2 VLANs + Tuning + GPU](#6-full-example)
7. [DRA Driver Orchestration Flow](#7-dra-driver-orchestration-flow)
8. [Validation: Claim ↔ NetworkTopology Mismatch](#8-validation-claim--networktopology-mismatch)
9. [Future: CNI Plugin Schema CRD](#9-future-cni-plugin-schema-crd-plugin-self-description)
9b. [Coexistence with OVN-Kubernetes (OKEP-6391)](#9b-coexistence-with-ovn-kubernetes-okep-6391)
    - [UDN Secondary with GPU Co-location](#9b2-use-case-a-udn-secondary-with-gpu-co-location)
    - [Localnet as Shared Device](#9b3-use-case-b-localnet-as-shared-device)
    - [Localnet + Tuning Chain](#9b4-use-case-c-localnet--tuning-chain)
10. [Open Questions](#10-open-questions)

---

## 1. Problem Statement

Today's DRA network drivers face a fundamental limitation: **complex network
topologies cannot be expressed declaratively within the DRA API**.

A Telco CNF or AI workload that needs bonded SR-IOV VFs with VLAN
sub-interfaces and per-interface tuning must either:

- Use **dra-driver-sriov in MULTUS mode** — coordinating 9+ YAML objects
  across two API surfaces (DRA + Multus/CNI), manually matching interface
  names, resource names, and CNI plugin ordering.
- Use **DRANET** — clean DRA-native experience but *cannot create composite
  topologies* (no bond, no VLAN, no chained configuration).
- Create the topology **manually inside the pod** with init containers and
  `NET_ADMIN` — fragile, not declarative, invisible to the scheduler.

### Goal

Provide a single DRA-native workflow where:

1. The user declares the **full network topology** (VFs → bond → VLANs → tuning)
   in a new **NetworkTopology CRD**.
2. A controller generates **DeviceClasses and opaque config** from the
   NetworkTopology, using only existing DRA API fields.
3. The DRA driver reads the opaque config, resolves the dependency graph,
   and executes the configuration in the pod's network namespace — all before
   the application container starts.

---

## 2. The NetworkTopology CRD

The `NetworkTopology` is a **cluster-scoped CRD** owned by the platform team.
It describes a directed acyclic graph (DAG) of network configuration steps.

### 2.1 Two kinds of steps

Steps are divided by whether they have a `dependOn` field:

**Root steps (no `dependOn`)** — these are **DRA device allocations**.  They
go through the scheduler, match against ResourceSlices, and consume real
hardware.  The `type` field on a root step is the CNI binary that the driver
invokes to attach the allocated device to the pod (e.g. `sriov`, `host-device`,
`bridge`).  The `selector.cel` expression is copied into a generated
DeviceClass.

**Derived steps (have `dependOn`)** — these are **CNI plugin calls** that run
after the root devices are attached.  The `type` field is the name of the CNI
binary to execute (e.g. `bond`, `vlan`, `tuning`, `macvlan`, `bridge`).  They
do not appear in ResourceSlices and do not consume physical capacity.  The
driver invokes them in topological order, passing `prevResult` from their
dependencies — exactly like a CNI chain.

| Step kind | `dependOn` | `type` field meaning | Scheduler involved? | Consumes from `prevResult` | Produces |
|-----------|-----------|---------------------|--------------------|----|----------|
| **Root** | absent | CNI binary for device attachment (e.g. `sriov`, `host-device`) | Yes — allocates from ResourceSlice | — (starts fresh) | `interfaces[]` with the attached device |
| **Derived** | present | CNI binary for configuration (e.g. `bond`, `vlan`, `tuning`) | No — pure node-local CNI call | `interfaces[]` from dependencies | `interfaces[]` with new/modified entries |

### 2.2 The `dependOn` field

Each step can declare `dependOn: [<step-name>, ...]`.  This creates the DAG:

```
     vf0 ──┐
            ├── bond0 ──┬── vlan100 ── tune-vlan100
     vf1 ──┘            └── vlan200 ── tune-vlan200
```

The driver **topologically sorts** the DAG to determine execution order and
**merges `prevResult`** from all dependencies before passing it to each step.

### 2.3 Parameterized config — referencing CNI results

The `config` block of each step is the CNI plugin configuration that gets
passed to the binary.  Values can contain **parameter references** of the form
`{{ <stepName>.<field> }}` that the driver resolves at execution time from the
CNI result (StepResult) of the referenced step.

Available fields follow the CNI ADD success result type.  For plugins that
produce network interfaces (sriov, bond, vlan, tuning):

| Reference | Resolves to |
|-----------|------------|
| `{{ <step>.interfaceName }}` | The `name` of the last interface in `<step>`'s `result.interfaces[]` |
| `{{ <step>.mac }}` | The `mac` of the last interface in `<step>`'s `result.interfaces[]` |
| `{{ <step>.sandbox }}` | The `sandbox` path from `<step>`'s result |
| `{{ <step>.ips[N].address }}` | The Nth IP address from `<step>`'s `result.ips[]` |
| `{{ <step>.interfaces }}` | The full `interfaces[]` array (used by bond to know which interfaces to enslave) |

For plugins that produce device nodes instead of interfaces (vfio-pci, rdma):

| Reference | Resolves to |
|-----------|------------|
| `{{ <step>.pciAddress }}` | The PCI BDF address of the device (e.g. `"0000:03:00.2"`) |
| `{{ <step>.iommuGroup }}` | The IOMMU group number |
| `{{ <step>.deviceNodes }}` | The list of character device paths (e.g. `["/dev/vfio/42"]`) |
| `{{ <step>.rdmaDevice }}` | The RDMA link device name (e.g. `"mlx5_0"`) |

The driver processes these **just before invoking each CNI binary**: it walks
the config JSON, finds all `{{ ... }}` tokens, looks up the referenced step's
StepResult (which has already executed because of topological ordering), and
substitutes the value.

### 2.4 CRD definition

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: NetworkTopology
metadata:
  name: bonded-vlan-topology
spec:
  steps:
    # --- Root steps (no dependOn): DRA device allocations ---
    # type = CNI binary used to attach the device (e.g. sriov, host-device)
    - name: vf0
      type: sriov
      selector:
        cel: >-
          device.driver == "dra.networking" &&
          device.attributes["dra.networking"].pfName == "enp3s0f0" &&
          device.attributes["dra.networking"].rdma == true
      config:
        vlan: 0
        spoofchk: "off"
        trust: "on"

    - name: vf1
      type: sriov
      selector:
        cel: >-
          device.driver == "dra.networking" &&
          device.attributes["dra.networking"].pfName == "enp3s0f1" &&
          device.attributes["dra.networking"].rdma == true
      config:
        vlan: 0
        spoofchk: "off"
        trust: "on"

    # --- Derived steps (have dependOn): CNI plugin calls ---
    # type = CNI binary to invoke (bond, vlan, tuning, macvlan, etc.)
    # config values can use {{ stepName.field }} to reference CNI results

    - name: bond0
      type: bond
      dependOn: [vf0, vf1]
      config:
        name: bond0
        mode: 802.3ad
        xmitHashPolicy: layer3+4
        miimon: 100
        lacpRate: fast
        links:                                    # slave interfaces
          - name: "{{ vf0.interfaceName }}"       # resolves to "net1"
          - name: "{{ vf1.interfaceName }}"       # resolves to "net2"

    - name: vlan100
      type: vlan
      dependOn: [bond0]
      config:
        id: 100
        master: "{{ bond0.interfaceName }}"       # resolves to "bond0"
        name: data0

    - name: vlan200
      type: vlan
      dependOn: [bond0]
      config:
        id: 200
        master: "{{ bond0.interfaceName }}"       # resolves to "bond0"
        name: mgmt0

    - name: tune-vlan100
      type: tuning
      dependOn: [vlan100]
      config:
        dev: "{{ vlan100.interfaceName }}"      # resolves to "data0"
        mtu: 9000
        addresses:
          - "10.100.0.5/24"
        routes:
          - destination: "10.100.0.0/16"
            gateway: "10.100.0.1"
        ethtool:
          features:
            rx-checksum: true
            tcp-segmentation-offload: true

    - name: tune-vlan200
      type: tuning
      dependOn: [vlan200]
      config:
        dev: "{{ vlan200.interfaceName }}"      # resolves to "mgmt0"
        mtu: 1500
        addresses:
          - "10.200.0.5/24"
        routes:
          - destination: "0.0.0.0/0"
            gateway: "10.200.0.1"
```

---

## 3. Step Result Model (inspired by CNI)

The [CNI specification](https://www.cni.dev/docs/spec/) defines a chaining
model where each plugin receives a `prevResult` from the previous plugin and
outputs a modified result.  We adopt the same principle but extend it from a
**linear chain to a DAG**.

### 3.1 The result structure

Every step produces a **StepResult**, modelled after the CNI ADD success type:

```json
{
  "interfaces": [
    {
      "name": "net1",
      "mac": "52:54:00:12:34:56",
      "sandbox": "/var/run/netns/<pod>",
      "pciID": "0000:03:00.2"
    }
  ],
  "ips": [
    {
      "address": "10.100.0.5/24",
      "gateway": "10.100.0.1",
      "interface": 0
    }
  ],
  "routes": [
    {
      "dst": "10.100.0.0/16",
      "gw": "10.100.0.1"
    }
  ]
}
```

### 3.2 How `prevResult` flows through the DAG

In CNI's linear chain, each plugin receives the single `prevResult` from the
previous plugin.  In a DAG the step may have **multiple dependencies**, so the
driver **merges** their results before passing them.

The `prevResult` provides two things:

1. **The `prevResult` JSON** — passed to the CNI binary via stdin (standard
   CNI protocol).  The plugin can inspect it to discover existing interfaces.
2. **The parameter reference namespace** — `{{ stepName.field }}` expressions
   in the step's `config` are resolved from the dependency's StepResult
   *before* the CNI binary is invoked.  This is how the bond knows its
   slave names and the VLAN knows its parent name.

| Scenario | `prevResult` construction | Parameter references available |
|----------|--------------------------|-------------------------------|
| **No dependency** (root step) | No `prevResult` — the CNI binary starts fresh (first plugin in chain) | None — root steps don't reference other steps |
| **One dependency** (e.g. vlan100 depends on bond0) | `prevResult` = bond0's StepResult verbatim (identical to CNI) | `{{ bond0.interfaceName }}`, `{{ bond0.mac }}`, etc. |
| **Multiple dependencies** (e.g. bond0 depends on vf0 + vf1) | `prevResult.interfaces` = **concatenation** of all dependency `interfaces[]` lists, in `dependOn` declaration order | `{{ vf0.interfaceName }}`, `{{ vf1.interfaceName }}`, etc. — each dependency's result is independently addressable |

### 3.3 Walkthrough: bond receives two VF results

After `vf0` and `vf1` execute (CNI ADD `sriov`), they each produce one
interface entry:

**vf0 StepResult:**
```json
{
  "interfaces": [
    { "name": "net1", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc" }
  ]
}
```

**vf1 StepResult:**
```json
{
  "interfaces": [
    { "name": "net2", "mac": "52:54:00:aa:bb:02", "sandbox": "/var/run/netns/pod-abc" }
  ]
}
```

The driver prepares the **bond0** step:

1. **Resolve parameter references** in bond0's config:
   - `{{ vf0.interfaceName }}` → `"net1"` (last interface in vf0's result)
   - `{{ vf1.interfaceName }}` → `"net2"` (last interface in vf1's result)
   - The config `links` becomes `[{name: "net1"}, {name: "net2"}]`

2. **Build merged `prevResult`** from both dependencies:

```json
{
  "interfaces": [
    { "name": "net1", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc" },
    { "name": "net2", "mac": "52:54:00:aa:bb:02", "sandbox": "/var/run/netns/pod-abc" }
  ]
}
```

3. **Invoke** CNI ADD `bond` with the resolved config + `prevResult`.

The bond CNI plugin creates `bond0`, enslaves `net1` and `net2`, and returns:

```json
{
  "interfaces": [
    { "name": "net1", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc" },
    { "name": "net2", "mac": "52:54:00:aa:bb:02", "sandbox": "/var/run/netns/pod-abc" },
    { "name": "bond0", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc" }
  ]
}
```

This becomes **bond0's StepResult**.  `{{ bond0.interfaceName }}` now
resolves to `"bond0"` (the last entry in `interfaces[]`).

### 3.4 Walkthrough: VLANs reference the bond interface

The **vlan100** step depends on `bond0`.  The driver:

1. **Resolves** `{{ bond0.interfaceName }}` → `"bond0"` in the config:
   `master: "bond0"`, `name: "data0"`
2. **Sets** `prevResult` = bond0's StepResult.
3. **Invokes** CNI ADD `vlan`.

The vlan CNI plugin creates `data0` (VLAN 100) on parent `bond0` and returns:

**vlan100 StepResult:**
```json
{
  "interfaces": [
    { "name": "net1", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc" },
    { "name": "net2", "mac": "52:54:00:aa:bb:02", "sandbox": "/var/run/netns/pod-abc" },
    { "name": "bond0", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc" },
    { "name": "data0", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc" }
  ]
}
```

`{{ vlan100.interfaceName }}` now resolves to `"data0"`.

The **vlan200** step follows the same pattern independently (also depends
on `bond0`):

**vlan200 StepResult:**
```json
{
  "interfaces": [
    { "name": "net1", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc" },
    { "name": "net2", "mac": "52:54:00:aa:bb:02", "sandbox": "/var/run/netns/pod-abc" },
    { "name": "bond0", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc" },
    { "name": "mgmt0", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc" }
  ]
}
```

`{{ vlan200.interfaceName }}` now resolves to `"mgmt0"`.

### 3.5 Walkthrough: tuning references the VLAN interface

**tune-vlan100** depends on `vlan100`.  The driver:

1. **Resolves** `{{ vlan100.interfaceName }}` → `"data0"` in the config:
   `dev: "data0"`.
2. **Sets** `prevResult` = vlan100's StepResult.
3. **Invokes** CNI ADD `tuning`.

The tuning plugin sets MTU 9000, adds `10.100.0.5/24`, adds routes on
`data0`, and outputs the result with `ips` and `routes` populated:

```json
{
  "interfaces": [
    { "name": "net1", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc" },
    { "name": "net2", "mac": "52:54:00:aa:bb:02", "sandbox": "/var/run/netns/pod-abc" },
    { "name": "bond0", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc" },
    { "name": "data0", "mac": "52:54:00:aa:bb:01", "sandbox": "/var/run/netns/pod-abc", "mtu": 9000 }
  ],
  "ips": [
    { "address": "10.100.0.5/24", "gateway": "10.100.0.1", "interface": 3 }
  ],
  "routes": [
    { "dst": "10.100.0.0/16", "gw": "10.100.0.1" }
  ]
}
```

> The `"interface": 3` index points to `data0` in the interfaces array,
> following the same convention as CNI.

---

## 4. From NetworkTopology to DRA Objects

A **controller** watches `NetworkTopology` resources and generates the
corresponding DRA objects.  No changes to the DRA API are needed — everything
is expressed through existing fields.

### 4.1 DeviceClass generation

For every **root step** (a step with no `dependOn`), the controller creates a
`DeviceClass`.  The step's `selector.cel` expression is copied into the
DeviceClass's `spec.selectors[]`.

```
NetworkTopology "bonded-vlan-topology"
  step vf0 (type: sriov, no dependOn)   ──►  DeviceClass "bonded-vlan-topology-vf0"
  step vf1 (type: sriov, no dependOn)   ──►  DeviceClass "bonded-vlan-topology-vf1"
  step bond0 (type: bond, dependOn)     ──►  (no DeviceClass — CNI call only)
  step vlan100 (type: vlan, dependOn)   ──►  (no DeviceClass — CNI call only)
  ...
```

The generated DeviceClass for `vf0` — note the `config` block carries the
`networkTopologyRef` and the step name so the DRA driver knows what to do:

```yaml
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: bonded-vlan-topology-vf0
  labels:
    networking.dra.io/topology: bonded-vlan-topology
    networking.dra.io/step: vf0
spec:
  selectors:
    - cel:
        expression: >-
          device.driver == "dra.networking" &&
          device.attributes["dra.networking"].pfName == "enp3s0f0" &&
          device.attributes["dra.networking"].rdma == true
  # The opaque config is baked into the DeviceClass by the controller.
  # Every device allocated through this class automatically carries the
  # topology reference — the user never needs to set it.
  config:
    - opaque:
        driver: dra.networking
        parameters:
          networkTopologyRef:
            name: bonded-vlan-topology
          step: vf0
```

The controller generates an identical DeviceClass for `vf1` (with `step: vf1`
and the corresponding CEL selector).

### 4.2 What the user writes

Because the `networkTopologyRef` is embedded in the DeviceClass, the **user's
ResourceClaim is completely clean** — no opaque config, no topology
references.  The user only needs to know the DeviceClass names:

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: my-network
spec:
  spec:
    devices:
      requests:
        - name: vf0
          exactly:
            deviceClassName: bonded-vlan-topology-vf0
        - name: vf1
          exactly:
            deviceClassName: bonded-vlan-topology-vf1
```

That's it.  No opaque config, no `networkTopologyRef`, no knowledge of bonds
or VLANs.  The platform admin encapsulated all of that in the NetworkTopology
and the generated DeviceClasses.

To add a GPU with PCIe co-location, the user simply adds a request and a
constraint:

```yaml
requests:
  - name: gpu
    exactly:
      deviceClassName: nvidia-gpu-h100
  - name: vf0
    exactly:
      deviceClassName: bonded-vlan-topology-vf0
  - name: vf1
    exactly:
      deviceClassName: bonded-vlan-topology-vf1
constraints:
  - matchAttribute: device.k8s.io/pcieRoot
    requests: [gpu, vf0, vf1]
```

### 4.3 How the DRA driver reconstructs the topology

When the DRA driver receives the allocation during `NodePrepareResources`,
each allocated device carries the opaque config from its DeviceClass.  The
driver:

1. Collects all opaque configs with `driver: dra.networking`.
2. Groups them by `networkTopologyRef.name` — all devices pointing to the
   same NetworkTopology are part of the same chain.
3. Fetches the `NetworkTopology` CR.
4. Maps each allocated device to its root step using the `step` field from
   the opaque config (e.g. device from `bonded-vlan-topology-vf0` → step
   `vf0`).
5. Builds the full DAG, resolves parameter references, and executes the
   CNI chain in topological order.

### 4.4 Why only root steps get DeviceClasses

- **Root steps** (no `dependOn`) allocate real hardware.  They need to go
  through the scheduler, which means they need DeviceClasses and
  ResourceSlice matching.  The CEL selector on the root step is exactly
  what the DeviceClass needs.  The `type` field names the CNI binary
  that attaches the allocated device (e.g. `sriov` moves a VF into the
  pod netns, `host-device` moves a whole PF).

- **Derived steps** (have `dependOn`) are pure node-local CNI plugin calls.
  They don't consume devices from ResourceSlices — the scheduler doesn't
  need to know about them.  The `type` field names the CNI binary that
  performs the configuration (e.g. `bond` creates a bond, `vlan` creates a
  sub-interface, `tuning` sets sysctls and ethtool features).

---

## 5. DeviceClass Design for Mixed NICs + GPUs

For AI workloads, we need GPUs and NICs on the same PCIe root complex.
Both the NVIDIA GPU DRA driver and the network DRA driver already publish the
standard attribute `device.k8s.io/pcieRoot` on their ResourceSlices.

The existing DRA API supports this through `constraints[].matchAttribute`
in the ResourceClaim — no API extensions needed.

### How it works

1. The **GPU DeviceClass** is created separately (by NVIDIA or the platform
   team), selecting GPU devices.
2. The **NIC DeviceClasses** are generated from the NetworkTopology's root
   steps.
3. The **ResourceClaim** contains requests for both GPU and NICs, with a
   `matchAttribute` constraint on `device.k8s.io/pcieRoot` across them.

The scheduler evaluates both drivers' ResourceSlices and finds a node where
a GPU and both VFs share the same PCIe root — all before pod placement.

The GPU and the network topology live in a **single ResourceClaim**, which
means the scheduler sees them atomically.  This is possible because each
request in the claim references a different DeviceClass, and different
drivers can serve different requests within the same claim.

---

## 6. Full Example

### 6.1 NetworkTopology

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: NetworkTopology
metadata:
  name: ai-bonded-rdma
spec:
  steps:
    - name: vf0
      type: sriov
      selector:
        cel: >-
          device.driver == "dra.networking" &&
          device.attributes["dra.networking"].pfName == "enp3s0f0" &&
          device.attributes["dra.networking"].rdma == true
      config:
        vlan: 0
        spoofchk: "off"
        trust: "on"

    - name: vf1
      type: sriov
      selector:
        cel: >-
          device.driver == "dra.networking" &&
          device.attributes["dra.networking"].pfName == "enp3s0f1" &&
          device.attributes["dra.networking"].rdma == true
      config:
        vlan: 0
        spoofchk: "off"
        trust: "on"

    - name: bond0
      type: bond
      dependOn: [vf0, vf1]
      config:
        name: bond0
        mode: 802.3ad
        xmitHashPolicy: layer3+4
        miimon: 100
        lacpRate: fast
        links:
          - name: "{{ vf0.interfaceName }}"
          - name: "{{ vf1.interfaceName }}"

    - name: data-vlan
      type: vlan
      dependOn: [bond0]
      config:
        id: 100
        master: "{{ bond0.interfaceName }}"
        name: data0

    - name: mgmt-vlan
      type: vlan
      dependOn: [bond0]
      config:
        id: 200
        master: "{{ bond0.interfaceName }}"
        name: mgmt0

    - name: tune-data
      type: tuning
      dependOn: [data-vlan]
      config:
        dev: "{{ data-vlan.interfaceName }}"
        mtu: 9000
        addresses:
          - "10.100.0.5/24"
        routes:
          - destination: "10.100.0.0/16"
            gateway: "10.100.0.1"
        ethtool:
          features:
            tcp-segmentation-offload: true

    - name: tune-mgmt
      type: tuning
      dependOn: [mgmt-vlan]
      config:
        dev: "{{ mgmt-vlan.interfaceName }}"
        mtu: 1500
        addresses:
          - "10.200.0.5/24"
        routes:
          - destination: "0.0.0.0/0"
            gateway: "10.200.0.1"
```

### 6.2 Generated DeviceClasses (by controller)

The controller generates one DeviceClass per root step, with the
`networkTopologyRef` and `step` baked into the opaque config:

```yaml
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: ai-bonded-rdma-vf0
  labels:
    networking.dra.io/topology: ai-bonded-rdma
    networking.dra.io/step: vf0
spec:
  selectors:
    - cel:
        expression: >-
          device.driver == "dra.networking" &&
          device.attributes["dra.networking"].pfName == "enp3s0f0" &&
          device.attributes["dra.networking"].rdma == true
  config:
    - opaque:
        driver: dra.networking
        parameters:
          networkTopologyRef:
            name: ai-bonded-rdma
          step: vf0
---
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: ai-bonded-rdma-vf1
  labels:
    networking.dra.io/topology: ai-bonded-rdma
    networking.dra.io/step: vf1
spec:
  selectors:
    - cel:
        expression: >-
          device.driver == "dra.networking" &&
          device.attributes["dra.networking"].pfName == "enp3s0f1" &&
          device.attributes["dra.networking"].rdma == true
  config:
    - opaque:
        driver: dra.networking
        parameters:
          networkTopologyRef:
            name: ai-bonded-rdma
          step: vf1
```

> The GPU DeviceClass already exists (e.g. created by NVIDIA's operator):

```yaml
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: nvidia-gpu-h100
spec:
  selectors:
    - cel:
        expression: >-
          device.driver == "gpu.nvidia.com" &&
          device.attributes["gpu.nvidia.com"].productName == "H100"
```

### 6.3 ResourceClaimTemplate (user creates this)

The user's claim is clean — no opaque config, no topology references.
The user only needs to know the DeviceClass names:

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: ai-gpu-bonded-rdma
spec:
  spec:
    devices:
      requests:
        # GPU — handled by NVIDIA DRA driver
        - name: gpu
          exactly:
            deviceClassName: nvidia-gpu-h100

        # NIC VFs — handled by network DRA driver
        - name: vf0
          exactly:
            deviceClassName: ai-bonded-rdma-vf0

        - name: vf1
          exactly:
            deviceClassName: ai-bonded-rdma-vf1

      # PCIe co-location: GPU + both VFs on the same PCIe root
      constraints:
        - matchAttribute: device.k8s.io/pcieRoot
          requests: [gpu, vf0, vf1]
```

### 6.4 Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ai-training
spec:
  resourceClaims:
    - name: accelerators
      resourceClaimTemplateName: ai-gpu-bonded-rdma
  containers:
    - name: train
      image: nvcr.io/nvidia/pytorch:24.05-py3
      resources:
        claims:
          - name: accelerators
```

### 6.5 What happens at runtime

```
                      ┌─────────────────────────────────────────────────┐
  User creates:       │  NetworkTopology: ai-bonded-rdma                │
                      │  ResourceClaimTemplate: ai-gpu-bonded-rdma      │
                      │  Pod: ai-training                               │
                      └────────────────────┬────────────────────────────┘
                                           │
                                           ▼
  ┌───────────────────────────────────────────────────────────────────────┐
  │ kube-scheduler                                                       │
  │                                                                      │
  │  1. Evaluate "gpu" request against NVIDIA ResourceSlices             │
  │  2. Evaluate "vf0" request against network ResourceSlices            │
  │  3. Evaluate "vf1" request against network ResourceSlices            │
  │  4. Enforce matchAttribute: all three share pcieRoot "pci0000:8e"    │
  │  5. Pick node, write AllocationResult                                │
  └──────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
  ┌───────────────────────────────────────────────────────────────────────┐
  │ kubelet → NodePrepareResources (DRA gRPC)                            │
  │                                                                      │
  │  NVIDIA driver: receives gpu allocation → prepares CDI spec          │
  │                                                                      │
  │  Network driver: receives vf0 + vf1 allocations + opaque config      │
  │    1. Read networkTopologyRef → fetch NetworkTopology "ai-bonded-rdma"│
  │    2. Build DAG: vf0,vf1 → bond0 → vlan100,vlan200 → tune-*         │
  │    3. Map allocated devices: vf0 → enp3s0f0v2, vf1 → enp3s0f1v2     │
  │    4. Bind VF drivers, generate CDI specs                            │
  │    5. Persist full step chain to checkpoint store                     │
  └──────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
  ┌───────────────────────────────────────────────────────────────────────┐
  │ NRI RunPodSandbox hook (pod netns exists)                            │
  │                                                                      │
  │  Step 1 — vf0:  CNI ADD "sriov" (deviceID=0000:03:00.2)             │
  │    sriov plugin: moves VF into pod netns, renames to net1            │
  │    result: interfaces=[{name:net1, mac:..., sandbox:...}]            │
  │                                                                      │
  │  Step 2 — vf1:  CNI ADD "sriov" (deviceID=0000:03:01.2)             │
  │    sriov plugin: moves VF into pod netns, renames to net2            │
  │    result: interfaces=[{name:net2, mac:..., sandbox:...}]            │
  │                                                                      │
  │  Step 3 — bond0: CNI ADD "bond"                                      │
  │    prevResult = merge(vf0.result, vf1.result)                        │
  │    → receives interfaces: [{name:net1,...}, {name:net2,...}]          │
  │    bond plugin: creates bond0, enslaves net1 + net2                  │
  │    result: interfaces=[..., {name:bond0,...}]                         │
  │                                                                      │
  │  Step 4 — data-vlan: CNI ADD "vlan"                                  │
  │    prevResult = bond0.result                                         │
  │    → parent = last interface = "bond0"                               │
  │    vlan plugin: creates data0 (VLAN 100) on bond0                    │
  │    result: interfaces=[..., {name:data0,...}]                         │
  │                                                                      │
  │  Step 5 — mgmt-vlan: CNI ADD "vlan"                                  │
  │    prevResult = bond0.result                                         │
  │    → parent = last interface = "bond0"                               │
  │    vlan plugin: creates mgmt0 (VLAN 200) on bond0                    │
  │    result: interfaces=[..., {name:mgmt0,...}]                         │
  │                                                                      │
  │  Step 6 — tune-data: CNI ADD "tuning"                                │
  │    prevResult = data-vlan.result                                     │
  │    tuning plugin: sets MTU 9000, adds 10.100.0.5/24, adds routes     │
  │                                                                      │
  │  Step 7 — tune-mgmt: CNI ADD "tuning"                                │
  │    prevResult = mgmt-vlan.result                                     │
  │    tuning plugin: sets MTU 1500, adds 10.200.0.5/24, default route   │
  │                                                                      │
  │  Update ResourceClaim status with per-device NetworkDeviceData       │
  └──────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
  ┌───────────────────────────────────────────────────────────────────────┐
  │ Application containers start                                         │
  │                                                                      │
  │  Pod sees:                                                           │
  │    /dev/nvidia0       ← GPU (from NVIDIA DRA driver)                 │
  │    net1, net2         ← VF interfaces (bond slaves)                  │
  │    bond0              ← LACP bond                                    │
  │    data0 (VLAN 100)   ← 10.100.0.5/24, MTU 9000                     │
  │    mgmt0 (VLAN 200)   ← 10.200.0.5/24, MTU 1500                     │
  │                                                                      │
  │  GPU and NICs share PCIe root pci0000:8e → GPUDirect-RDMA capable    │
  └───────────────────────────────────────────────────────────────────────┘
```

---

## 7. DRA Driver Orchestration Flow

### 7.1 Phase 1: NodePrepareResources

1. Receive the `AllocationResult` from kubelet.
2. For each opaque config block with a `networkTopologyRef`, fetch the
   `NetworkTopology` CR from the API server.
3. Build the step DAG from `spec.steps[]` and their `dependOn` fields.
   Validate: no cycles, all references valid.
4. For each root step (no `dependOn`), map the DRA-allocated device to the
   step by request name: the ResourceClaim request named `vf0` allocated
   device X → root step `vf0` gets device X.
5. For each root step: bind the VF driver (kernel / vfio-pci), generate
   CDI spec entries.
6. Persist the full step chain (DAG + configs + device mappings) to the
   checkpoint store, keyed by pod UID.

### 7.2 Phase 2: NRI RunPodSandbox

1. Pod sandbox is created by the container runtime.  NRI hook fires.
2. Load the persisted step chain for this pod UID.
3. Topologically sort all steps.
4. Execute each step in order.  Every step is a **CNI binary invocation**:

   | Step | CNI binary (`type`) | CNI_COMMAND | Input | Output (`prevResult` for next step) |
   |------|-------|-------------|-------|--------|
   | Root (e.g. `vf0`) | `sriov` | ADD | Config with `deviceID` (PCI address of the allocated VF) | `interfaces[]` with the VF attached in pod netns |
   | Root (e.g. `vf1`) | `sriov` | ADD | Config with `deviceID` | `interfaces[]` with the VF attached in pod netns |
   | `bond0` | `bond` | ADD | `prevResult` = merged `interfaces[]` from vf0 + vf1 | `interfaces[]` with bond appended |
   | `vlan100` | `vlan` | ADD | `prevResult` = bond0's result | `interfaces[]` with VLAN appended |
   | `tune-vlan100` | `tuning` | ADD | `prevResult` = vlan100's result | `interfaces[]` with modified attrs, plus `ips[]` and `routes[]` |

   For each invocation the driver:
   - Builds the CNI config JSON from the step's `config` block, injecting
     `cniVersion`, `name`, `type`, and (for root steps) `runtimeConfig.deviceID`.
   - Sets `prevResult` from the merged dependency results.
   - Calls the CNI binary via `libcni` (using `chroot /proc/1/root` for
     host filesystem access, same pattern as `dra-driver-sriov`).
   - Captures the CNI result as the step's `StepResult`.

5. After each step, store its StepResult.
6. After all steps complete, update the `ResourceClaim` status with
   `NetworkDeviceData` for each configured interface.

### 7.3 Rollback

If any step fails, the driver calls `CNI_COMMAND=DEL` on all completed steps
in **reverse topological order** (matching the CNI delete protocol):

1. Tuning steps: `DEL` (undo sysctls, remove IPs/routes).
2. VLAN steps: `DEL` (remove sub-interface).
3. Bond steps: `DEL` (destroy bond, releases slaves).
4. Root steps: `DEL` (move device back to host netns).
5. Update ResourceClaim status with failure reason on the failing step.

---

## 8. Validation: Claim ↔ NetworkTopology Mismatch

The **user owns the ResourceClaim** (so they can freely add GPU requests,
cross-device constraints, etc.).  The **controller only generates
DeviceClasses** from the NetworkTopology's root steps.  This means the user
could submit a claim that references a NetworkTopology but is missing one or
more root step requests.

Two enforcement points catch this — a webhook for fast feedback and the driver
as a safety net.

### 8.1 Validating Admission Webhook

The network DRA driver deploys a **validating webhook** on `ResourceClaim` and
`ResourceClaimTemplate` create/update.  When any opaque config block contains a
`networkTopologyRef`, the webhook:

1. Fetches the referenced `NetworkTopology` CR.
2. Collects all **root step names** (steps with no `dependOn`).
3. Collects all **request names** in the claim whose opaque config carries the
   same `networkTopologyRef`.
4. Compares the two sets.

If there is a mismatch the webhook **rejects the request**:

```
admission webhook "validate.networking.dra.io" denied the request:
  NetworkTopology "ai-bonded-rdma" requires root step requests [vf0, vf1],
  but ResourceClaimTemplate "ai-gpu-bonded-rdma" only provides requests [vf0].
  Missing: [vf1]
```

The user gets immediate feedback at `kubectl apply` time — before a pod is
even created.  Crucially the webhook only validates that the network root steps
are present; it **ignores** any additional requests (e.g. GPU) since those
belong to other drivers.

### 8.2 DRA Driver at NodePrepareResources (safety net)

If the webhook is not installed, was temporarily unavailable, or is bypassed,
the driver catches the mismatch at prepare time:

1. Driver receives the `AllocationResult` with opaque config pointing to
   `networkTopologyRef: ai-bonded-rdma`.
2. Driver fetches the `NetworkTopology`, builds the DAG, identifies root steps
   `[vf0, vf1]`.
3. Driver maps allocated devices to root steps by matching request names.
4. Root step `vf1` has **no matching allocated device** → driver returns an
   error from `NodePrepareResources`.

The kubelet surfaces this as a pod event:

```
Warning  FailedPrepare  pod/ai-training
  NodePrepareResources failed: NetworkTopology "ai-bonded-rdma" root step "vf1"
  has no matching device request in ResourceClaim "ai-gpu-bonded-rdma".
  The ResourceClaim must contain a request named "vf1" with
  deviceClassName "ai-bonded-rdma-vf1".
```

The pod stays `Pending` and the user sees exactly what is missing.

### 8.3 Summary

| Enforcement Point | When | User Sees |
|---|---|---|
| **Validating webhook** | `kubectl apply` of the claim | Immediate rejection with missing request names |
| **DRA driver** | After scheduling, on the node | Pod event with failure reason, pod stays Pending |

---

## 9. Future: CNI Plugin Schema CRD (Plugin Self-Description)

> **Status:** Optional / future implementation.  Not required for the initial
> proposal but would significantly improve the user experience and enable
> compile-time-like validation of NetworkTopology DAGs.

### 9.1 Problem

Today, CNI plugins are opaque binaries.  There is no machine-readable
description of:

- What **config parameters** a plugin accepts (e.g. the `bond` plugin
  accepts `mode`, `miimon`, `links`; the `vlan` plugin accepts `id`,
  `master`).
- What **input** the plugin requires from `prevResult` (e.g. the `bond`
  plugin requires at least 2 entries in `prevResult.interfaces`; the
  `tuning` plugin requires at least 1).
- What **output** the plugin produces (e.g. the `bond` plugin appends one
  interface; the `vlan` plugin appends one interface; the `tuning` plugin
  modifies an existing interface and may add `ips`/`routes`).

Without this, the DRA driver can only validate the NetworkTopology DAG
**structurally** (no cycles, references exist) but cannot validate
**semantically** (will the bond actually get 2 interfaces? does the tuning
plugin understand the `ethtool` field?).  Errors are discovered only at
runtime when the CNI binary fails.

### 9.2 The CNIPluginSchema CRD

Each CNI plugin vendor ships a **`CNIPluginSchema`** CR alongside the CNI
binary.  It is a cluster-scoped CRD that describes the plugin's contract:

```yaml
apiVersion: cni.networking.k8s.io/v1alpha1
kind: CNIPluginSchema
metadata:
  name: bond
spec:
  # The CNI binary name (matches the `type` field in NetworkTopology steps)
  cniType: bond
  version: "1.0.0"

  # --- Config parameters accepted by this plugin ---
  configParameters:
    required:
      - name: mode
        type: string
        description: "Bond mode"
        enum: ["balance-rr", "active-backup", "balance-xor", "broadcast",
               "802.3ad", "balance-tlb", "balance-alb"]
      - name: links
        type: "[]object"
        description: "Slave interfaces to enslave"
        minItems: 2
        items:
          properties:
            name:
              type: string
              description: "Interface name (supports {{ step.interfaceName }} references)"
    optional:
      - name: name
        type: string
        description: "Name for the bond device"
        default: "bond0"
      - name: xmitHashPolicy
        type: string
        enum: ["layer2", "layer3+4", "layer2+3", "encap2+3", "encap3+4"]
      - name: miimon
        type: integer
        description: "Link monitoring interval in ms"
      - name: lacpRate
        type: string
        enum: ["slow", "fast"]

  # --- What this plugin requires from prevResult ---
  input:
    prevResult:
      required: true
      interfaces:
        minItems: 2                    # bond needs at least 2 slaves
        maxItems: 8                    # kernel BOND_MAX_SLAVES practical limit
      ips:
        required: false                # bond doesn't need IPs on input
      routes:
        required: false

  # --- What this plugin produces in its result ---
  output:
    interfaces:
      appends: 1                       # adds exactly one interface (the bond)
      passthrough: true                # also passes through all input interfaces
    ips:
      passthrough: true                # passes through any existing IPs
    routes:
      passthrough: true
```

```yaml
apiVersion: cni.networking.k8s.io/v1alpha1
kind: CNIPluginSchema
metadata:
  name: vlan
spec:
  cniType: vlan
  version: "1.0.0"

  configParameters:
    required:
      - name: id
        type: integer
        description: "VLAN ID"
        minimum: 1
        maximum: 4094
      - name: master
        type: string
        description: "Parent interface (supports {{ step.interfaceName }} references)"
    optional:
      - name: name
        type: string
        description: "Name for the VLAN sub-interface"

  input:
    prevResult:
      required: true
      interfaces:
        minItems: 1                    # needs at least the parent interface

  output:
    interfaces:
      appends: 1                       # adds the VLAN sub-interface
      passthrough: true
    ips:
      passthrough: true
    routes:
      passthrough: true
```

```yaml
apiVersion: cni.networking.k8s.io/v1alpha1
kind: CNIPluginSchema
metadata:
  name: sriov
spec:
  cniType: sriov
  version: "1.0.0"

  configParameters:
    required: []
    optional:
      - name: vlan
        type: integer
        minimum: 0
        maximum: 4094
      - name: spoofchk
        type: string
        enum: ["on", "off"]
      - name: trust
        type: string
        enum: ["on", "off"]
      - name: mac
        type: string

  # Root plugin — no prevResult needed
  input:
    prevResult:
      required: false

  output:
    interfaces:
      appends: 1                       # the VF moved into the pod netns
      passthrough: false               # root plugin, nothing to pass through
    ips:
      passthrough: false
    routes:
      passthrough: false
```

Not all device plugins produce network interfaces.  A **VFIO-PCI** plugin
binds the VF to the `vfio-pci` kernel driver and exposes it as character
device nodes (`/dev/vfio/<group>`) — there is no `interfaces[]` entry in
the result because the device is not a kernel netdev.  The schema must be
able to express this:

```yaml
apiVersion: cni.networking.k8s.io/v1alpha1
kind: CNIPluginSchema
metadata:
  name: vfio-pci
spec:
  cniType: vfio-pci
  version: "1.0.0"

  configParameters:
    required: []
    optional:
      - name: driver
        type: string
        description: "Kernel driver to bind (vfio-pci, igb_uio, uio_pci_generic)"
        enum: ["vfio-pci", "igb_uio", "uio_pci_generic"]
        default: "vfio-pci"

  input:
    prevResult:
      required: false

  # VFIO devices produce NO network interfaces — they expose device nodes
  output:
    interfaces:
      appends: 0
      passthrough: false
    ips:
      passthrough: false
    routes:
      passthrough: false
    # Device nodes exposed to the container via CDI
    devices:
      appends: true                    # produces /dev/vfio/<group>, /dev/vfio/vfio
      properties:
        - name: pciAddress
          type: string
          description: "PCI BDF address of the bound device"
        - name: iommuGroup
          type: string
          description: "IOMMU group number"
        - name: deviceNodes
          type: "[]string"
          description: "Paths to character devices (e.g. /dev/vfio/42)"
```

This has two important implications for DAG validation:

1. **A VFIO step cannot be a dependency of bond/vlan/tuning** — those
   plugins require `interfaces.minItems >= 1`, but `vfio-pci` produces
   `interfaces.appends: 0`.  The webhook rejects this at create time:

   ```
   admission webhook "validate.networking.dra.io" denied the request:
     NetworkTopology "bad-dpdk", step "bond0":
       CNIPluginSchema "bond" requires at least 2 interfaces in prevResult,
       but dependency "dpdk-vf" uses plugin "vfio-pci" which produces 0 interfaces.
       VFIO devices cannot be bonded — they are userspace-managed.
   ```

2. **A VFIO step can be a leaf in the DAG** — it's a root step that
   allocates a device and binds it to vfio-pci.  No further CNI chaining
   is possible (or needed — DPDK apps manage the device from userspace).

3. **Parameter references from VFIO steps** use `devices` fields instead
   of `interfaces` fields:

   | Reference | Resolves to |
   |-----------|------------|
   | `{{ dpdk-vf.pciAddress }}` | The PCI BDF address (e.g. `"0000:03:00.2"`) |
   | `{{ dpdk-vf.iommuGroup }}` | The IOMMU group (e.g. `"42"`) |
   | `{{ dpdk-vf.deviceNodes }}` | The device node paths |

This also applies to other non-netdev attachment types like **RDMA-only
devices** (InfiniBand without ethernet) that expose `/dev/infiniband/*`
character devices but may not have a kernel network interface:

```yaml
apiVersion: cni.networking.k8s.io/v1alpha1
kind: CNIPluginSchema
metadata:
  name: rdma
spec:
  cniType: rdma
  version: "1.0.0"

  configParameters:
    optional:
      - name: rdmaDevice
        type: string
        description: "RDMA device name (e.g. mlx5_0)"

  input:
    prevResult:
      required: false

  output:
    # RDMA devices may or may not have an associated network interface
    interfaces:
      appends: 0                       # no netdev for IB-only devices
      passthrough: false
      conditional: true                # may produce an interface for RoCE devices
    devices:
      appends: true
      properties:
        - name: rdmaDevice
          type: string
          description: "RDMA link device name (e.g. mlx5_0)"
        - name: deviceNodes
          type: "[]string"
          description: "Character devices (/dev/infiniband/uverbs0, rdma_cm, etc.)"
```

```yaml
apiVersion: cni.networking.k8s.io/v1alpha1
kind: CNIPluginSchema
metadata:
  name: tuning
spec:
  cniType: tuning
  version: "1.0.0"

  configParameters:
    required: []
    optional:
      - name: dev
        type: string
        description: "Target interface (supports {{ step.interfaceName }} references)"
      - name: mtu
        type: integer
      - name: addresses
        type: "[]string"
        description: "IP addresses in CIDR notation"
      - name: routes
        type: "[]object"
        items:
          properties:
            destination: { type: string }
            gateway: { type: string }
      - name: ethtool
        type: object
        properties:
          features:
            type: "map[string]bool"
      - name: sysctl
        type: "map[string]string"

  input:
    prevResult:
      required: true
      interfaces:
        minItems: 1                    # needs the interface to tune

  output:
    interfaces:
      appends: 0                       # doesn't create new interfaces
      passthrough: true                # passes through all existing
      modifies: true                   # may change MTU, MAC on existing
    ips:
      appends: true                    # may add IPs
      passthrough: true
    routes:
      appends: true                    # may add routes
      passthrough: true
```

### 9.3 Validation at NetworkTopology creation time

When the user creates or updates a `NetworkTopology`, the validating webhook
uses the `CNIPluginSchema` CRs to perform **semantic DAG validation**:

**For each step, the webhook:**

1. **Looks up** the `CNIPluginSchema` matching the step's `type` field.
   If not found, skip validation for that step (backward compatible with
   plugins that don't ship a schema).

2. **Validates config parameters:**
   - All `required` parameters are present in the step's `config`.
   - No unknown parameters (unless the schema allows additional fields).
   - Values match declared types, enums, min/max constraints.
   - `{{ ref }}` expressions are only used in fields of type `string`.

3. **Validates input requirements against the DAG:**
   - If `input.prevResult.required: true`, the step **must** have a
     `dependOn` (cannot be a root step).
   - If `input.prevResult.interfaces.minItems: 2`, the step must depend on
     steps whose combined output produces at least 2 interfaces.  The
     webhook computes this by walking the DAG and summing up each
     dependency's `output.interfaces.appends` + passthrough counts.

4. **Computes the step's output** for downstream validation:
   - Number of interfaces = (input passthrough count) + `output.interfaces.appends`
   - Whether `ips`/`routes` are available for `{{ ref }}` expressions.

**Example validation error:**

```
admission webhook "validate.networking.dra.io" denied the request:
  NetworkTopology "broken-topology", step "bond0":
    CNIPluginSchema "bond" requires at least 2 interfaces in prevResult,
    but step "bond0" depends on [vf0] which produces only 1 interface.
    Add another VF step to dependOn.
```

Another example — unknown config parameter:

```
admission webhook "validate.networking.dra.io" denied the request:
  NetworkTopology "bad-config", step "vlan100":
    CNIPluginSchema "vlan" does not accept parameter "vlanId".
    Did you mean "id"?
```

### 9.4 How plugin vendors ship the schema

Each CNI plugin is packaged as a **Helm chart** that deploys:

1. A **DaemonSet** whose init container copies the CNI binary to the host
   and whose main container sleeps (keeps the DaemonSet alive for upgrades
   and node auto-scaling).
2. The **CNIPluginSchema CR** applied as a Helm template.

```
cni-plugin-bond/                       # Helm chart
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── daemonset.yaml                 # DaemonSet that installs the binary
│   └── cnipluginschema.yaml           # CNIPluginSchema CR
└── image/
    └── /opt/cni/bin/bond              # CNI binary inside the container image
```

The DaemonSet:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cni-plugin-bond
spec:
  selector:
    matchLabels:
      app: cni-plugin-bond
  template:
    spec:
      initContainers:
        - name: install
          image: registry.example.com/cni-plugins/bond:v1.0.0
          command: ["cp", "/opt/cni/bin/bond", "/host/opt/cni/bin/"]
          volumeMounts:
            - name: cni-bin
              mountPath: /host/opt/cni/bin
      containers:
        - name: wait
          image: registry.example.com/cni-plugins/bond:v1.0.0
          command: ["sleep", "infinity"]
      volumes:
        - name: cni-bin
          hostPath:
            path: /opt/cni/bin
```

`helm install cni-bond ./cni-plugin-bond` deploys the DaemonSet on every node
and applies the `CNIPluginSchema` CR to the cluster.

#### Future: DRA Network Operator

In the future, the manual Helm-per-plugin model can be replaced by a
**DRA Network Operator** that manages plugin lifecycle declaratively:

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: CNIPlugin
metadata:
  name: bond
spec:
  image: registry.example.com/cni-plugins/bond:v1.0.0
  binaryPath: /opt/cni/bin/bond
```

The operator would:

1. Deploy the DaemonSet automatically from the `CNIPlugin` CR.
2. Extract and apply the `CNIPluginSchema` from the container image.
3. Handle upgrades (rolling binary replacement across nodes).
4. Garbage-collect removed plugins (delete DaemonSet + schema).
5. Report plugin health per node via status conditions.

### 9.5 Summary

| Aspect | Without CNIPluginSchema | With CNIPluginSchema |
|--------|------------------------|---------------------|
| **Config validation** | Runtime failure (CNI binary returns error code 7) | Webhook rejects at `kubectl apply` time |
| **DAG wiring validation** | Runtime failure (e.g. bond gets 1 interface instead of 2) | Webhook computes interface counts across the DAG |
| **Parameter discovery** | Read plugin docs, trial and error | `kubectl get cnipluginschema bond -o yaml` |
| **Typo detection** | Runtime failure | Webhook suggests corrections |
| **Backward compatibility** | N/A | Plugins without a schema are not validated (pass-through) |


---

## 9b. Coexistence with OVN-Kubernetes (OKEP-6391)

OVN-Kubernetes is developing its own DRA driver (`driver: k8s.ovn.org`,
see [OKEP-6391](https://github.com/ovn-kubernetes/ovn-kubernetes/pull/6446))
for first-party accelerated networking. Our generic DRA network driver
(`driver: dra.networking`) coexists cleanly because DRA natively supports
multiple drivers in the same cluster.

### 9b.1 OVN-K Network Types

OVN-K supports three secondary network topologies, all using
`ovn-k8s-cni-overlay` as the CNI binary:

| Topology | How pods connect | Device on host | DRA model |
|---|---|---|---|
| **layer2** (UDN) | VF moved to pod (accelerated) or veth pair | Switchdev VF with representor on `br-int` | Exclusive VF per pod |
| **layer3** (UDN) | Same as layer2 | Same | Exclusive VF per pod |
| **localnet** (CUDN) | veth pair | PF/bridge mapped via `ovn-bridge-mappings` | Shared underlay (multi-alloc) |

### 9b.2 Use Case A: UDN Secondary with GPU Co-location

The most natural integration: a single accelerated VF per pod for a UDN
secondary network, with `matchAttribute` for GPU co-location.



#### NetworkTopology

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: NetworkTopology
metadata:
  name: ovnk-udn-accelerated
spec:
  steps:
    - name: ovn-vf
      type: ovn-k8s-cni-overlay
      selector:
        cel: >-
          device.driver == "dra.networking" &&
          device.attributes["dra.networking"].type == "vf" &&
          device.attributes["dra.networking"].pfName == "enp5s0f0"
      config:
        topology: layer2
        role: secondary
        netAttachDefName: "default/tenant-blue"
        subnets: "172.31.0.0/24"
```

#### ResourceClaimTemplate with GPU co-location

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: ai-ovnk-aligned
spec:
  spec:
    devices:
      requests:
        - name: gpu
          exactly:
            deviceClassName: nvidia-gpu-h100
        - name: ovn-vf
          exactly:
            deviceClassName: ovnk-udn-accelerated-ovn-vf
      constraints:
        - matchAttribute: device.k8s.io/pcieRoot
          requests: [gpu, ovn-vf]
```

The scheduler ensures the GPU and the OVN-K VF share the same PCIe root —
optimal for GPUDirect-RDMA on the UDN secondary network.

### 9b.3 Use Case B: Localnet as Shared Device

Localnet networks map a logical switch to a physical network via OVS
bridge-mappings. Pods connect via veth pairs — the physical uplink stays
on the host. This maps to `allowMultipleAllocations: true`.

#### DeviceExposurePolicy

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: DeviceExposurePolicy
metadata:
  name: localnet-uplink
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
    additionalAttributes:
      "dra.networking/physicalNetworkName": "localnet1"
```

#### NetworkTopology

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: NetworkTopology
metadata:
  name: ovnk-localnet
spec:
  steps:
    - name: localnet-port
      type: ovn-k8s-cni-overlay
      selector:
        cel: >-
          device.driver == "dra.networking" &&
          device.attributes["dra.networking"].physicalNetworkName == "localnet1"
      config:
        topology: localnet
        role: secondary
        physicalNetworkName: "localnet1"
        netAttachDefName: "default/localnet-blue"
        subnets: "192.168.100.0/24"
        vlanID: 200
```

### 9b.4 Use Case C: Localnet + Tuning Chain

Chain a tuning step after localnet for MTU or sysctl settings:

```yaml
apiVersion: networking.dra.io/v1alpha1
kind: NetworkTopology
metadata:
  name: ovnk-localnet-tuned
spec:
  steps:
    - name: localnet-port
      type: ovn-k8s-cni-overlay
      selector:
        cel: >-
          device.driver == "dra.networking" &&
          device.attributes["dra.networking"].physicalNetworkName == "localnet1"
      config:
        topology: localnet
        role: secondary
        physicalNetworkName: "localnet1"
        netAttachDefName: "default/localnet-blue"
        subnets: "192.168.100.0/24"

    - name: tune-localnet
      type: tuning
      dependOn: [localnet-port]
      config:
        dev: "{{ localnet-port.interfaceName }}"
        mtu: 9000
        sysctl:
          net.core.somaxconn: "512"
```

One root step (OVN-K creates veth + OVN plumbing) + one derived step
(tuning sets MTU and sysctl) — the simplest chaining example.

### 9b.5 Preventing Driver Conflicts

When both drivers run on the same cluster, partition devices:

| Device | Managed by | How |
|---|---|---|
| Switchdev VFs on `enp5s0f0` | Our generic driver | `DeviceExposurePolicy` exposes them |
| Switchdev VFs on `enp4s0f0` | OVN-K's driver | OVN-K publishes under `k8s.ovn.org` |
| Localnet uplink `enp6s0f0` | Our generic driver | `DeviceExposurePolicy` with `allowMultipleAllocations` |

Configure OVN-K to exclude our driver's devices:

```
ovnkube-node --dra-filter='!("k8s.ovn.org/ifName" in attributes) || attributes["k8s.ovn.org/ifName"].StringValue != "enp5s0f0"'
```

---

## 10. Open Questions

| # | Question | Notes |
|---|----------|-------|
| 1 | How to handle NetworkTopology updates while pods are running? | Likely immutable once referenced by a ResourceClaim. Controller rejects edits. |
| 2 | ResourceSlice and device discovery for the network DRA driver. | See companion document: [DRA ResourceSlice Discovery Brainstorm](dra-resourceslice-discovery-brainstorm.md) |
