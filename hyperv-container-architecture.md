# Hyper-V Container Architecture in Kubernetes

## Overview

This document explains how Hyper-V isolated containers work in Kubernetes on Windows nodes, including the complete stack from pod creation to container runtime execution.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         Kubernetes API Server                   │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           │ Watch Pods
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Mutating Admission Webhook                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ Intercepts: Pod CREATE/UPDATE                            │   │
│  │ Action: Injects runtimeClassName: runhcs-wcow-hypervisor │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           │ Modified Pod Spec
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Windows Node                            │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                      Kubelet                            │    │
│  │  - Reads RuntimeClass from Pod Spec                     │    │
│  │  - Looks up RuntimeClass handler in config              │    │
│  └──────────────────────┬──────────────────────────────────┘    │
│                         │ CRI (Container Runtime Interface)     │
│                         ▼                                       │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    containerd                            │   │
│  │  ┌───────────────────────────────────────────────────┐   │   │
│  │  │ Runtime Handlers (config.toml):                   │   │   │
│  │  │                                                   │   │   │
│  │  │ [plugins."io.containerd.grpc.v1.cri".containerd]  │   │   │
│  │  │   default_runtime_name = "runhcs-wcow-process"    │   │   │
│  │  │                                                   │   │   │
│  │  │   [plugins...runtimes.runhcs-wcow-process]        │   │   │
│  │  │     runtime_type = "io.containerd.runhcs.v1"      │   │   │
│  │  │     pod_annotations = ["*"]                       │   │   │
│  │  │     container_annotations = ["*"]                 │   │   │
│  │  │     [options]                                     │   │   │
│  │  │       Debug = true                                │   │   │
│  │  │       DebugType = 2                               │   │   │
│  │  │                                                   │   │   │
│  │  │   [plugins...runtimes.runhcs-wcow-hypervisor]     │   │   │
│  │  │     runtime_type = "io.containerd.runhcs.v1"      │   │   │
│  │  │     pod_annotations = ["*"]                       │   │   │
│  │  │     container_annotations = ["*"]                 │   │   │
│  │  │     [options]                                     │   │   │
│  │  │       Debug = true                                │   │   │
│  │  │       DebugType = 2                               │   │   │
│  │  │       SandboxIsolation = 1  ◄─────────────────    │   │   │
│  │  └───────────────────────────────────────────────────┘   │   │
│  └──────────────────────┬───────────────────────────────────┘   │
│                         │                                       │
│                         ▼                                       │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                      runhcs                             │    │
│  │  (Hyper-V Shim - handles Windows container execution)   │    │
│  │  - Receives SandboxIsolation = 1 (Hyper-V)              │    │
│  │  - Creates Hyper-V utility VM                           │    │
│  │  - Mounts container image layers                        │    │
│  └──────────────────────┬──────────────────────────────────┘    │
│                         │                                       │
│                         ▼                                       │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              Host Compute Service (HCS)                 │    │
│  │  Windows API for managing containers and VMs            │    │
│  └──────────────────────┬──────────────────────────────────┘    │
│                         │                                       │
│                         ▼                                       │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │               Hyper-V Hypervisor                        │    │
│  │  ┌───────────────────────────────────────────────────┐  │    │
│  │  │         Utility VM (Hyper-V Isolated)             │  │    │
│  │  │  ┌─────────────────────────────────────────────┐  │  │    │
│  │  │  │      Container Process                      │  │  │    │
│  │  │  │  - Runs in isolated kernel                  │  │  │    │
│  │  │  │  - Own memory space                         │  │  │    │
│  │  │  │  - Stronger security boundary               │  │  │    │
│  │  │  └─────────────────────────────────────────────┘  │  │    │
│  │  └───────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Component Breakdown

### 1. Kubernetes API Server & RuntimeClass

**Important: Two Separate Layers**

There's a crucial distinction between:
1. **containerd runtime handlers** (built-in, node-level) - Always present in containerd v1.7+ config
2. **Kubernetes RuntimeClass resources** (cluster-level) - Must be manually created

| Aspect           | containerd Handler                              | Kubernetes RuntimeClass   |
| ---------------- | ----------------------------------------------- | ------------------------- |
| **Location**     | Node config file (config.toml)                  | Cluster API resource      |
| **Created by**   | `containerd config default`                     | Manual `kubectl apply`    |
| **Availability** | ✅ Both handlers exist by default                | ❌ No default RuntimeClass |
| **Scope**        | Per-node configuration                          | Cluster-wide abstraction  |
| **Examples**     | `runhcs-wcow-process`, `runhcs-wcow-hypervisor` | Must create YAML          |

**RuntimeClass** is a Kubernetes resource that maps to containerd runtime handlers:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: runhcs-wcow-hypervisor
handler: runhcs-wcow-hypervisor  # ◄── Maps to containerd runtime handler
scheduling:
  nodeSelector:
    kubernetes.io/os: 'windows'
  tolerations:
  - effect: NoSchedule
    key: os
    operator: Equal 
    value: "windows"
```

**Key Points:**
- `handler` field must match a runtime handler name in containerd's config
- `scheduling` ensures pods only land on Windows nodes
- RuntimeClass is referenced in Pod spec: `spec.runtimeClassName: runhcs-wcow-hypervisor`
- **RuntimeClass resource MUST be created** even though the containerd handler already exists
- Without RuntimeClass, pods can only use containerd's `default_runtime_name` (process isolation)

### 2. Mutating Admission Webhook (Optional but Automated)

In the testing setup, a **mutating admission webhook** automatically injects the RuntimeClass:

**What it does:**
```go
// For every pod being created/updated:
if pod.Spec.RuntimeClassName == nil {
    // Automatically set Hyper-V runtime
    pod.Spec.RuntimeClassName = &"runhcs-wcow-hypervisor"
}
```

**Exceptions:**
- HostProcess containers (can't use Hyper-V isolation)
- Pods explicitly labeled for Linux

**Why it's useful:**
- Developers don't need to manually specify runtimeClassName
- Existing e2e tests automatically run with Hyper-V isolation
- Transparent to applications

**Note:** The webhook is **optional**. You can create Hyper-V containers without it by:
1. Creating the RuntimeClass resource manually
2. Explicitly setting `spec.runtimeClassName: runhcs-wcow-hypervisor` in pod specs

This gives fine-grained control over which workloads use Hyper-V isolation.

### 3. Kubelet (Container Runtime Interface Client)

**Role:** 
- Watches for pods assigned to its node
- Reads `spec.runtimeClassName` from pod
- Calls containerd via CRI with the runtime handler name

**CRI Request Example:**
```protobuf
RunPodSandboxRequest {
  config: PodSandboxConfig {
    metadata: { name: "my-pod", namespace: "default" }
    runtime_handler: "runhcs-wcow-hypervisor"  // ◄── From RuntimeClass
  }
}
```

### 4. containerd (Container Runtime)

**Configuration File:** `/etc/containerd/config.toml` (Linux) or `C:\Program Files\containerd\config.toml` (Windows)

**Key Configuration Sections:**

```toml
version = 2

[plugins."io.containerd.grpc.v1.cri".containerd]
  # Default runtime when no runtimeClassName specified
  default_runtime_name = "runhcs-wcow-process"

  # Process-isolated containers (default)
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runhcs-wcow-process]
    runtime_type = "io.containerd.runhcs.v1"
    pod_annotations = ["*"]
    container_annotations = ["*"]
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runhcs-wcow-process.options]
      Debug = true
      DebugType = 2
      # SandboxIsolation = 0 (default - process isolation)

  # Hyper-V isolated containers
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runhcs-wcow-hypervisor]
    runtime_type = "io.containerd.runhcs.v1"
    pod_annotations = ["*"]
    container_annotations = ["*"]
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runhcs-wcow-hypervisor.options]
      Debug = true
      DebugType = 2
      SandboxIsolation = 1  # ◄── 1 = Hyper-V isolation
```

**How containerd Processes the Request:**

1. **Receives CRI request** with `runtime_handler = "runhcs-wcow-hypervisor"`
2. **Looks up runtime handler** in config.toml
3. **Finds matching runtime:** `runtimes.runhcs-wcow-hypervisor`
4. **Extracts options:**
   - `runtime_type = "io.containerd.runhcs.v1"` → Use runhcs shim
   - `SandboxIsolation = 1` → Enable Hyper-V isolation
5. **Invokes runhcs shim** with these options

### 5. runhcs (Runtime Shim)

**Full name:** Run Host Compute Service (runhcs)

**Purpose:** Windows-specific container shim that interfaces with the Windows Host Compute Service (HCS)

**GitHub:** https://github.com/microsoft/hcsshim

**What it does:**

1. **Receives containerd request** with:
   ```json
   {
     "SandboxIsolation": 1,  // 0 = process, 1 = Hyper-V
     "LayerFolders": ["C:\\ProgramData\\containerd\\..."],
     "NetworkEndpoints": [...],
     "Memory": {...},
     "Processors": {...}
   }
   ```

2. **Translates to HCS API calls:**
   ```
   HcsCreateComputeSystem()
   - Type: VirtualMachine (for Hyper-V) or Container (for process)
   - Configuration: CPU, memory, network, storage
   ```

3. **For Hyper-V isolation:**
   - Creates a lightweight **Utility VM** (not a full Windows VM)
   - Mounts container image layers into the VM
   - Starts the container process inside the VM
   - Manages lifecycle (start, stop, kill)

4. **Maintains connection** between containerd and the container process

### 6. Host Compute Service (HCS)

**Location:** Built into Windows kernel (vmcompute.sys, vmwp.exe)

**API:** COM-based Windows API

**Responsibilities:**

- **Process Isolation:**
  - Uses Windows Server containers (shared kernel)
  - Similar to Linux namespaces and cgroups
  - Lightweight, fast startup

- **Hyper-V Isolation:**
  - Creates a minimal Utility VM using Hyper-V
  - Each container runs in its own kernel
  - Stronger isolation, slightly higher overhead

**HCS Utility VM Characteristics:**

- **Minimal OS:** Stripped-down Windows kernel (not full Windows)
- **Size:** ~30-40 MB memory overhead
- **Boot time:** ~2-3 seconds (much faster than full VM)
- **Purpose-built:** Only includes what's needed for containers
- **Shared image layers:** Multiple containers can share base layers

### 7. Hyper-V Hypervisor

**Type:** Type 1 hypervisor (bare metal)

**Role in Container Isolation:**

- Provides hardware-level isolation between Utility VMs
- Each container gets:
  - **Isolated kernel:** Own Windows kernel instance
  - **Isolated memory:** Cannot access host or other container memory
  - **Isolated CPU:** Scheduled independently
  - **Virtual devices:** Virtual network adapters, storage

**Security Benefits:**

- Kernel exploits in one container don't affect host or other containers
- Suitable for multi-tenant environments
- Required for running untrusted workloads

## Complete Flow: Pod to Running Container

### Step-by-Step Execution

1. **User creates Pod:**
   ```bash
   kubectl apply -f my-pod.yaml
   ```

2. **Mutating Webhook (if enabled):**
   - Intercepts pod creation
   - Adds: `spec.runtimeClassName: runhcs-wcow-hypervisor`
   - Adds annotation: `hyperv-runtimeclass-mutating-webhook: mutated`

3. **Scheduler:**
   - Uses RuntimeClass `scheduling` rules
   - Places pod on Windows node with required labels/tolerations

4. **Kubelet on Windows node:**
   - Watches pod assignment
   - Reads `spec.runtimeClassName`
   - Calls containerd CRI: `RunPodSandbox(runtime_handler="runhcs-wcow-hypervisor")`

5. **containerd:**
   - Looks up `runhcs-wcow-hypervisor` in config.toml
   - Finds: `runtime_type = "io.containerd.runhcs.v1"`
   - Reads options: `SandboxIsolation = 1`
   - Pulls container images (if needed)
   - Prepares image layers in Windows layer storage

6. **runhcs shim:**
   - Receives request from containerd
   - Calls HCS API: `HcsCreateComputeSystem()`
   - Parameters:
     ```
     Type: VirtualMachine
     Isolation: HyperV
     Layers: [base layer, app layer, scratch layer]
     Network: vNIC configuration
     Resources: CPU count, memory limit
     ```

7. **Host Compute Service (HCS):**
   - Instructs Hyper-V to create Utility VM
   - Configures VM resources (memory, CPU)
   - Attaches virtual network adapter
   - Mounts container layers as virtual disks

8. **Hyper-V Hypervisor:**
   - Allocates hardware resources
   - Creates isolated VM
   - Boots minimal Windows kernel in VM
   - Starts container process inside VM

9. **Container Running:**
   - Application process runs in Utility VM
   - Isolated from host and other containers
   - Network traffic flows through virtual NIC
   - Storage writes go to scratch layer

10. **Lifecycle Management:**
    - Kubelet → containerd → runhcs → HCS → Hyper-V
    - Stop, restart, kill commands flow through same path
    - Logs collected via CRI streaming API
    - Metrics gathered from HCS

## Isolation Comparison

### Process Isolation (Default)

```
┌─────────────────────────────────────┐
│         Windows Host Kernel         │
│                                     │
│  ┌──────────┐  ┌──────────┐         │
│  │Container │  │Container │         │
│  │    1     │  │    2     │         │
│  └──────────┘  └──────────┘         │
│                                     │
│  Shared kernel, namespace isolation │
└─────────────────────────────────────┘
```

**Characteristics:**
- Faster startup (~500ms)
- Lower memory overhead (~5-10 MB)
- Containers share host kernel
- Weaker isolation

### Hyper-V Isolation

```
┌─────────────────────────────────────────────┐
│            Hyper-V Hypervisor               │
│                                             │
│  ┌─────────────────┐  ┌─────────────────┐   │
│  │   Utility VM 1  │  │   Utility VM 2  │   │
│  │  ┌───────────┐  │  │  ┌───────────┐  │   │
│  │  │  Kernel   │  │  │  │  Kernel   │  │   │
│  │  ├───────────┤  │  │  ├───────────┤  │   │
│  │  │Container 1│  │  │  │Container 2│  │   │
│  │  └───────────┘  │  │  └───────────┘  │   │
│  └─────────────────┘  └─────────────────┘   │
└─────────────────────────────────────────────┘
```

**Characteristics:**
- Slower startup (~2-3 seconds)
- Higher memory overhead (~30-40 MB)
- Each container has own kernel
- Stronger isolation (hardware-level)

## Resource Limits and Requests

### Do Resource Limits Apply to Hyper-V Containers?

**Yes, Kubernetes resource requests and limits fully apply to Hyper-V containers.** The containerd/runhcs stack correctly translates Kubernetes resource specifications to both the Utility VM and the container running inside it.

### How Resources Are Applied

The [hcsshim](https://github.com/microsoft/hcsshim) code (specifically `internal/hcsoci/hcsdoc_wcow.go`) shows how Kubernetes resources map to Windows HCS parameters:

| Kubernetes Resource | HCS Parameter                                         | Description                    |
| ------------------- | ----------------------------------------------------- | ------------------------------ |
| `cpu` (limits)      | `ProcessorMaximum` / `ProcessorLimit`                 | CPU limit as fraction of 10000 |
| `cpu` (requests)    | `ProcessorCount`                                      | Number of vCPUs assigned       |
| `memory` (limits)   | `MemoryMaximumInMB` / `SizeInMB`                      | Maximum memory in MB           |
| Storage QoS         | `StorageQoSBandwidthMaximum`, `StorageQoSIopsMaximum` | I/O limits                     |

### Resource Flow in Hyper-V Containers

```
┌─────────────────────────────────────────────────────────────────┐
│ Kubernetes Pod Spec                                             │
│   resources:                                                    │
│     requests: { memory: 512Mi, cpu: 500m }                      │
│     limits:   { memory: 1Gi, cpu: 1000m }                       │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ containerd → runhcs-wcow-hypervisor                             │
│   - Parses OCI spec.Windows.Resources                           │
│   - Calls ConvertCPULimits() & ParseAnnotationsMemory()         │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Utility VM (UVM) - The Hyper-V VM                               │
│   - MemorySizeInMB: configures VM memory                        │
│   - ProcessorCount: configures vCPUs                            │
│   - ProcessorLimit: CPU throttling                              │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│ Container (inside UVM)                                          │
│   - Runs with job object CPU/Memory limits                      │
│   - Additional isolation from process containers                │
└─────────────────────────────────────────────────────────────────┘
```

### CPU Limit Scaling for Hyper-V (ScaleCPULimitsToSandbox)

An important detail: kubelet calculates CPU limits based on **host processors**, but the container runs inside a UVM with potentially fewer processors. The runhcs shim handles this with `ScaleCPULimitsToSandbox`:

```go
// From hcsshim/internal/hcsoci/hcsdoc_wcow.go
// When ScaleCPULimitsToSandbox is set and we are running in a UVM, we assume
// the CPU limit has been calculated based on the number of processors on the
// host, and instead re-calculate it based on the number of processors in the UVM.
newCPULimit := cpuLimit * hostCPUCount / uvmCPUCount
```

This ensures that millicores work correctly inside the Hyper-V VM regardless of how many vCPUs are assigned to the UVM.

### Utility VM Resource Overhead

The UVM itself has a **minimum resource footprint** in addition to your container's resources:

| Resource         | Default                 | Notes                             |
| ---------------- | ----------------------- | --------------------------------- |
| Memory           | ~1024 MB base           | Can be configured via annotations |
| CPUs             | Host count (normalized) | Can be limited                    |
| Disk             | ~350 MB                 | WCOW base layer                   |
| Startup overhead | ~2-3 seconds            | VM boot time                      |

When sizing Hyper-V containers, consider:

```yaml
# Example: Your container requests 512Mi, but the UVM needs ~1GB base
# Total memory consumed ≈ 512Mi (container) + UVM overhead
apiVersion: v1
kind: Pod
metadata:
  name: hyperv-resource-example
spec:
  runtimeClassName: runhcs-wcow-hypervisor
  containers:
  - name: app
    image: mcr.microsoft.com/windows/nanoserver:ltsc2022
    resources:
      requests:
        memory: "512Mi"   # For your workload
        cpu: "500m"       # 0.5 CPU cores
      limits:
        memory: "1Gi"     # Maximum your container can use
        cpu: "1000m"      # 1 full CPU core
```

### Verifying Resource Allocation

Check that Kubernetes has allocated the resources:

```bash
kubectl get pod <pod-name> -o yaml | grep -A 10 "resources:"
```

Example output showing resources are properly allocated:

```yaml
containerStatuses:
- allocatedResources:
    cpu: 500m
    memory: 512Mi
  resources:
    limits:
      cpu: "1"
      memory: 1Gi
    requests:
      cpu: 500m
      memory: 512Mi
```

### Resource Limits Best Practices for Hyper-V

1. **Account for UVM overhead** - Add ~40-100MB memory headroom for the Utility VM itself

2. **Set realistic CPU limits** - Each Hyper-V container has VM scheduling overhead

3. **Use QoS Class wisely**:
   - `Guaranteed`: Set requests = limits (best for production)
   - `Burstable`: Set different requests and limits (good for variable workloads)
   - `BestEffort`: No limits set (not recommended for Hyper-V due to overhead)

4. **Consider storage QoS** - Use annotations for I/O limits:
   ```yaml
   annotations:
     io.microsoft.container.storage.qos.bandwidthmaximum: "104857600"  # 100 MB/s
     io.microsoft.container.storage.qos.iopsmaximum: "1000"
   ```

5. **Monitor actual usage** - Hyper-V containers may use more memory than process containers for the same workload

## Configuration Files

### RuntimeClass (Kubernetes)

**Location:** Cluster-wide Kubernetes resource

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: runhcs-wcow-hypervisor
handler: runhcs-wcow-hypervisor
scheduling:
  nodeSelector:
    kubernetes.io/os: 'windows'
    kubernetes.io/arch: 'amd64'
  tolerations:
  - effect: NoSchedule
    key: os
    operator: Equal 
    value: "windows"
```

### containerd Configuration (Windows Node)

**Location:** `C:\Program Files\containerd\config.toml`

```toml
version = 2

[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.10"

[plugins."io.containerd.grpc.v1.cri".containerd]
  default_runtime_name = "runhcs-wcow-process"
  
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runhcs-wcow-process]
    runtime_type = "io.containerd.runhcs.v1"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runhcs-wcow-process.options]
      Debug = true
      DebugType = 2

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runhcs-wcow-hypervisor]
    runtime_type = "io.containerd.runhcs.v1"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runhcs-wcow-hypervisor.options]
      Debug = true
      DebugType = 2
      SandboxIsolation = 1  # Key difference: Hyper-V isolation
```

### Pod Specification

**With RuntimeClass:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hyperv-pod
spec:
  runtimeClassName: runhcs-wcow-hypervisor  # ◄── Triggers Hyper-V isolation
  containers:
  - name: app
    image: mcr.microsoft.com/windows/nanoserver:ltsc2022
    command: ["cmd", "/c", "ping -t localhost"]
```

**Without RuntimeClass (uses default - process isolation):**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: process-pod
spec:
  containers:
  - name: app
    image: mcr.microsoft.com/windows/nanoserver:ltsc2022
    command: ["cmd", "/c", "ping -t localhost"]
```

## Verification & Debugging

### How to Verify Hyper-V vs Process Isolation

After creating a container in your Kubernetes cluster, use these methods to verify the isolation type:

#### Method 1: Check Pod RuntimeClass (Kubernetes Level)

```bash
# Get the pod's RuntimeClass
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.spec.runtimeClassName}'

# Expected output for Hyper-V: runhcs-wcow-hypervisor
# No output or empty means using default (process isolation)

# Check if webhook added the annotation
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.metadata.annotations.hyperv-runtimeclass-mutating-webhook}'
# Expected output: mutated
```

**Example:**
```bash
$ kubectl get pod my-app -o jsonpath='{.spec.runtimeClassName}'
runhcs-wcow-hypervisor

$ kubectl get pod my-app -o yaml | grep runtimeClassName
  runtimeClassName: runhcs-wcow-hypervisor
```

#### Method 2: Check HCS Compute Systems (Windows Node - Most Reliable)

**Using hcsdiag (Recommended):**
```powershell
# SSH or RDP to the Windows node
# List all running containers and their types
hcsdiag list

# Output shows Type for each container:
# Type: VirtualMachine = Hyper-V isolation ✓
# Type: Container = Process isolation
```

**Example Output:**
```
Container ID: 1a2b3c4d-5e6f-7890-abcd-ef1234567890
Name: k8s_app_my-pod_default_12345678-1234-1234-1234-123456789012_0
Type: VirtualMachine  ◄── This confirms Hyper-V isolation
Owner: containerd
State: Running
```

**Using PowerShell Get-ComputeProcess (Verified Method):**
```powershell
# From a HostProcess pod (e.g., kube-proxy) or via node access
Get-ComputeProcess | Select-Object Id, Type, RuntimeId | Format-Table

# Type column shows:
# - VirtualMachine = Hyper-V isolation ✓
# - Container = Process isolation

# Example output for Hyper-V container:
# Id                                                                            Type           RuntimeId
# --                                                                            ----           ---------
# 29fff9f4b4a055cc7e3a7f5b5477ccf1779ce0624f8e0e3c965557a9b4d5da14@vm         VirtualMachine e237919f-f6be-5457-844c-f6f6c01896b8
```

**Using PowerShell Get-ComputeProcess (Alternative Format):**
```powershell
# Get all compute processes with their types
Get-ComputeProcess | Select-Object Name, Type, Owner, Id | Format-Table -AutoSize

# Type column shows:
# - VirtualMachine = Hyper-V isolation ✓
# - Container = Process isolation
```

**Example Output:**
```
Name                                                          Type           Owner       Id
----                                                          ----           -----       --
k8s_app_my-pod_default_12345678-1234-1234-1234-123456789012_0 VirtualMachine containerd  1a2b3c4d
k8s_sidecar_my-pod_default_12345678-1234-1234-1234-123456789012_0 VirtualMachine containerd  2b3c4d5e
```

#### Method 2.5: Check for VM Worker Processes (Quick Verification)

The presence of `vmwp.exe` and `vmmem.exe` processes confirms Hyper-V containers are running:

```powershell
# Check for Hyper-V VM worker processes
Get-Process | Where-Object {$_.ProcessName -like '*vmwp*' -or $_.ProcessName -like '*vmmem*'} | 
  Select-Object ProcessName, Id, CPU, @{Label="Memory(MB)";Expression={[math]::Round($_.WorkingSet/1MB,2)}} | 
  Format-Table

# Expected output for Hyper-V containers:
# ProcessName    Id     CPU Memory(MB)
# -----------    --     --- ----------
# vmmem       50736    1.59     371.72   ← Memory manager for Utility VMs
# vmwp        54824    1.63      24.11   ← VM Worker Process (one per Utility VM)

# No vmwp.exe/vmmem.exe = No Hyper-V containers running
```

#### Method 3: Check Hyper-V VMs (Windows Node)

Hyper-V isolated containers create utility VMs that are visible in Hyper-V Manager:

```powershell
# List all Hyper-V VMs (including utility VMs)
Get-VM

# Look for VMs with GUID names - these are container utility VMs
Get-VM | Where-Object { $_.State -eq 'Running' } | Format-Table Name, State, CPUUsage, MemoryAssigned

# Get details of a specific utility VM
Get-VM -Name <vm-guid> | Format-List *
```

**Example Output:**
```powershell
PS> Get-VM

Name                                    State   CPUUsage(%) MemoryAssigned(M)
----                                    -----   ----------- -----------------
1a2b3c4d-5e6f-7890-abcd-ef1234567890   Running 2           512
2b3c4d5e-6f78-9012-3456-789012345678   Running 1           512
```

**If you see VMs with GUID names and they're running → Hyper-V isolation is active**

**If no VMs appear → Process isolation**

#### Method 4: Inspect Container from Inside (Container Level)

SSH into the container and check kernel info:

```bash
# From your local machine, exec into the container
kubectl exec -it <pod-name> -- cmd

# Inside the container, check hostname
C:\> hostname
# Hyper-V containers show a VM GUID as hostname
# Process containers show the actual hostname
```

**Check if running in a VM:**
```powershell
kubectl exec -it <pod-name> -- powershell -Command "Get-ComputerInfo | Select-Object CsSystemType, CsManufacturer"

# Hyper-V output:
# CsSystemType : Virtual Machine
# CsManufacturer : Microsoft Corporation

# Check for Hyper-V VM
kubectl exec -it <pod-name> -- powershell -Command "systeminfo | findstr /C:'Hyper-V'"
```

#### Method 5: Check Process Tree (Windows Node)

Hyper-V containers run in `vmwp.exe` (VM Worker Process):

```powershell
# Check for vmwp.exe processes (Hyper-V VM worker)
Get-Process vmwp -ErrorAction SilentlyContinue | Format-Table Id, CPU, WorkingSet, ProcessName

# Each vmwp.exe process represents a Hyper-V utility VM
# Multiple vmwp.exe = multiple Hyper-V containers
# No vmwp.exe = no Hyper-V containers (all process isolated)
```

**Example Output:**
```
  Id    CPU    WorkingSet ProcessName
  ----  ---    ---------- -----------
  1234  15.2   524288000  vmwp
  5678  8.7    524288000  vmwp
```

#### Method 6: Check containerd Logs (Windows Node)

```powershell
# View containerd logs for container creation
Get-WinEvent -LogName Application -FilterHashtable @{ProviderName='containerd'} -MaxEvents 50 | 
  Where-Object { $_.Message -like '*SandboxIsolation*' }

# Look for: SandboxIsolation=1 (Hyper-V) or SandboxIsolation=0 (Process)
```

#### Method 7: Use ctr (containerd CLI) on Windows Node

```powershell
# List containers with runtime info
ctr -n k8s.io containers list

# Get detailed info about a specific container
ctr -n k8s.io container info <container-id>

# Look for runtime: "io.containerd.runhcs.v1"
# and check options for SandboxIsolation
```

#### Method 8: Check Windows Event Viewer (Windows Node)

1. Open Event Viewer on the Windows node
2. Navigate to: **Applications and Services Logs → Microsoft → Windows → Hyper-V-Worker → Admin**
3. Look for events with Event ID **18500** (VM Started)
4. Each event corresponds to a Hyper-V utility VM creation

**Or via PowerShell:**
```powershell
Get-WinEvent -LogName 'Microsoft-Windows-Hyper-V-Worker-Admin' -MaxEvents 20 | 
  Where-Object { $_.Id -eq 18500 } | 
  Format-Table TimeCreated, Message -AutoSize
```

### Complete Verification Workflow

**Step-by-step verification script:**

```powershell
# Run this on the Windows node to verify Hyper-V containers

Write-Host "`n=== Checking Hyper-V Container Status ===" -ForegroundColor Cyan

# 1. Check if Hyper-V feature is enabled
Write-Host "`n[1] Checking Hyper-V Feature..." -ForegroundColor Yellow
$hypervFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V
if ($hypervFeature.State -eq 'Enabled') {
    Write-Host "✓ Hyper-V is ENABLED" -ForegroundColor Green
} else {
    Write-Host "✗ Hyper-V is DISABLED" -ForegroundColor Red
}

# 2. Check for running Hyper-V VMs (utility VMs)
Write-Host "`n[2] Checking Hyper-V Utility VMs..." -ForegroundColor Yellow
$vms = Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' }
if ($vms.Count -gt 0) {
    Write-Host "✓ Found $($vms.Count) running Hyper-V VM(s)" -ForegroundColor Green
    $vms | Format-Table Name, State, CPUUsage, MemoryAssigned -AutoSize
} else {
    Write-Host "✗ No Hyper-V VMs found (containers may be process-isolated)" -ForegroundColor Red
}

# 3. Check HCS compute systems
Write-Host "`n[3] Checking HCS Compute Systems..." -ForegroundColor Yellow
$computeProcesses = Get-ComputeProcess
$hypervContainers = $computeProcesses | Where-Object { $_.Type -eq 'VirtualMachine' }
$processContainers = $computeProcesses | Where-Object { $_.Type -eq 'Container' }

Write-Host "Hyper-V isolated containers: $($hypervContainers.Count)" -ForegroundColor Green
Write-Host "Process isolated containers: $($processContainers.Count)" -ForegroundColor Cyan

if ($hypervContainers.Count -gt 0) {
    Write-Host "`nHyper-V Containers:" -ForegroundColor Green
    $hypervContainers | Select-Object Name, Type, Id | Format-Table -AutoSize
}

# 4. Check vmwp.exe processes (VM worker processes)
Write-Host "`n[4] Checking VM Worker Processes..." -ForegroundColor Yellow
$vmwpProcesses = Get-Process vmwp -ErrorAction SilentlyContinue
if ($vmwpProcesses) {
    Write-Host "✓ Found $($vmwpProcesses.Count) vmwp.exe process(es)" -ForegroundColor Green
    $vmwpProcesses | Format-Table Id, CPU, @{Label="Memory(MB)";Expression={[math]::Round($_.WorkingSet/1MB,2)}} -AutoSize
} else {
    Write-Host "✗ No vmwp.exe processes found" -ForegroundColor Red
}

# 5. Check containerd runtime configuration
Write-Host "`n[5] Checking containerd Configuration..." -ForegroundColor Yellow
$configPath = "C:\Program Files\containerd\config.toml"
if (Test-Path $configPath) {
    $config = Get-Content $configPath
    $hypervRuntime = $config | Select-String -Pattern "runhcs-wcow-hypervisor" -Context 0,5
    if ($hypervRuntime) {
        Write-Host "✓ Hyper-V runtime configured in containerd" -ForegroundColor Green
    } else {
        Write-Host "✗ Hyper-V runtime NOT found in containerd config" -ForegroundColor Red
    }
} else {
    Write-Host "✗ containerd config not found at $configPath" -ForegroundColor Red
}

Write-Host "`n=== Verification Complete ===" -ForegroundColor Cyan
```

### Quick Verification Commands Summary

```bash
# From Kubernetes management cluster:
kubectl get pod <pod-name> -o jsonpath='{.spec.runtimeClassName}'
# Expected: runhcs-wcow-hypervisor

# On Windows node:
Get-ComputeProcess | Select Type
# Look for: VirtualMachine (Hyper-V) vs Container (Process)

Get-VM
# Should show utility VMs if Hyper-V isolation is active

Get-Process vmwp
# Should show vmwp.exe processes for each Hyper-V container
```

### Visual Comparison

**Process Isolation - What You WON'T See:**
- ✗ No VMs in `Get-VM`
- ✗ No `vmwp.exe` processes
- ✗ `Get-ComputeProcess` shows Type: `Container`
- ✗ No Hyper-V-Worker events

**Hyper-V Isolation - What You WILL See:**
- ✓ Utility VMs with GUID names in `Get-VM`
- ✓ Multiple `vmwp.exe` processes running
- ✓ `Get-ComputeProcess` shows Type: `VirtualMachine`
- ✓ Hyper-V-Worker event logs showing VM creation
- ✓ Higher memory usage per container (~40MB overhead)
- ✓ Pod has `runtimeClassName: runhcs-wcow-hypervisor`

### Check RuntimeClass Configuration

```bash
# List all RuntimeClasses
kubectl get runtimeclass

# Get details
kubectl describe runtimeclass runhcs-wcow-hypervisor
```

### Check containerd Configuration

```powershell
# On Windows node
Get-Content "C:\Program Files\containerd\config.toml"

# Restart containerd after config changes
Restart-Service containerd
```

### containerd Logs

```bash
# On Linux (management cluster)
journalctl -u containerd -f

# On Windows node
Get-EventLog -LogName Application -Source containerd -Newest 50
```

### runhcs Logs

```powershell
# Enable debug logging in containerd config:
# Debug = true
# DebugType = 2

# Logs location (if configured):
C:\ProgramData\containerd\root\
```

## Performance Considerations

### When to Use Hyper-V Isolation

**Use Cases:**
- Multi-tenant environments (untrusted workloads)
- Running containers from untrusted images
- Compliance requirements for strong isolation
- Different kernel versions needed
- Security-critical applications

**Trade-offs:**
- Startup time: +1.5-2.5 seconds per pod
- Memory overhead: +30-40 MB per pod
- Slightly higher CPU overhead for VM management

### When to Use Process Isolation

**Use Cases:**
- Single-tenant environments
- Trusted workloads
- Performance-critical applications
- High pod density requirements
- Development/testing environments

**Benefits:**
- Faster pod startup
- Lower resource overhead
- Higher pod density per node

## Troubleshooting

### Common Issues

#### 1. RuntimeClass Not Found
```
Error: admission webhook "mpod.kb.io" denied the request: 
runtimeclass "runhcs-wcow-hypervisor" not found
```

**Solution:**
```bash
kubectl apply -f hyperv-runtimeclass.yaml
```

#### 2. containerd Can't Find Runtime Handler
```
Error: unknown runtime handler runhcs-wcow-hypervisor
```

**Solution:** Update containerd config.toml and restart:
```powershell
Restart-Service containerd
```

#### 3. Hyper-V Not Enabled
```
Error: Hyper-V feature is not enabled
```

**Solution:**
```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
Restart-Computer
```

#### 4. Pod Stuck in ContainerCreating
```bash
kubectl describe pod my-pod
# Check events for HCS errors
```

**Common causes:**
- Insufficient memory for Utility VM
- Network configuration issues
- Image pull failures
- Resource limits too low

## Security Implications

### Hyper-V Isolation Security Boundaries

**What Hyper-V Isolation Protects Against:**

1. **Kernel exploits in container**
   - Container has its own kernel
   - Exploit doesn't affect host kernel

2. **Container escape attempts**
   - Must escape VM, not just container namespace
   - Much harder attack surface

3. **Resource exhaustion**
   - VM has hard limits enforced by hypervisor
   - Can't exhaust host resources easily

4. **Side-channel attacks**
   - Hardware-level isolation reduces attack surface
   - Memory is isolated at VM level

**What It Doesn't Protect Against:**

1. **Hypervisor vulnerabilities**
   - If Hyper-V itself is compromised
   - Still better than process isolation

2. **Host-level attacks**
   - Network-based attacks on host
   - Physical access to host

3. **Supply chain attacks**
   - Malicious container images
   - Compromised base images

### Best Practices

1. **Use Hyper-V for untrusted workloads**
2. **Keep Windows and Hyper-V updated**
3. **Enable Windows Defender Application Control (WDAC)**
4. **Use Pod Security Standards**
5. **Limit container capabilities**
6. **Use read-only root filesystems where possible**
7. **Enable audit logging**

## References

- **Kubernetes RuntimeClass:** https://kubernetes.io/docs/concepts/containers/runtime-class/
- **containerd:** https://containerd.io/
- **runhcs/hcsshim:** https://github.com/microsoft/hcsshim
- **Windows Container Documentation:** https://learn.microsoft.com/en-us/virtualization/windowscontainers/
- **Hyper-V Containers:** https://learn.microsoft.com/en-us/virtualization/windowscontainers/manage-containers/hyperv-container
- **Windows Container Networking:** https://learn.microsoft.com/en-us/virtualization/windowscontainers/container-networking/architecture

## Appendix: Key Configuration Options

### containerd Runtime Options (runhcs)

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.<handler>.options]
  # Isolation type
  SandboxIsolation = 0  # 0 = process, 1 = Hyper-V
  
  # VM configuration (Hyper-V only)
  VmMemorySizeInMb = 512
  VmProcessorCount = 2
  
  # Debugging
  Debug = true
  DebugType = 2  # 0 = pipe, 1 = file, 2 = ETW
  
  # Security
  AllowOvercommit = false
  
  # Networking
  NetworkMode = "l2bridge"  # or "nat"
```

### RuntimeClass Scheduling

```yaml
scheduling:
  # Node affinity
  nodeSelector:
    kubernetes.io/os: 'windows'
    node.kubernetes.io/windows-build: '10.0.20348'
    
  # Tolerations for tainted nodes
  tolerations:
  - effect: NoSchedule
    key: os
    operator: Equal 
    value: "windows"
    
  # Overhead (optional - for better scheduling)
  overhead:
    podFixed:
      memory: "40Mi"
      cpu: "50m"
```
