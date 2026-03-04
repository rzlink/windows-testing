# Enabling Hyper-V E2E Testing in Kubernetes TestGrid

This document describes how to add periodic Hyper-V container e2e tests to the Kubernetes TestGrid for continuous visibility and regression detection.

## Overview

Hyper-V containers provide hardware-level isolation for Windows containers in Kubernetes. To ensure continuous testing of this feature, we need to add periodic jobs to the Kubernetes test infrastructure.

## Current State

### Existing Hyper-V Presubmit Job

There's already a presubmit job configured in `kubernetes/test-infra`:

- **File:** `config/jobs/kubernetes-sigs/sig-windows/release-master-windows-presubmits.yaml`
- **Job Name:** `pull-e2e-run-capz-sh-windows-2022-hyperv`
- **Dashboard:** `sig-windows-presubmit`
- **Status:** `optional: true`, `always_run: false`
- **Trigger:** Only runs when `helpers/hyper-v-mutating-webhook/.*` files change

```yaml
- name: pull-e2e-run-capz-sh-windows-2022-hyperv
  cluster: eks-prow-build-cluster
  always_run: false
  optional: true
  run_if_changed: 'helpers/hyper-v-mutating-webhook/.*'
  # ... configuration ...
  env:
  - name: HYPERV
    value: "true"
  - name: GINKGO_FOCUS
    value: \[Feature:WindowsHyperVContainers\]
  annotations:
    testgrid-dashboards: sig-windows-presubmit
    testgrid-tab-name: pull-e2e-run-capz-sh-windows-2022-hyperv
```

### What's Missing

- **No periodic job** - Hyper-V tests only run on PRs that touch the webhook code
- **No continuous visibility** - No TestGrid dashboard showing Hyper-V test health over time
- **No release blocking** - Hyper-V regressions won't be caught until someone manually triggers tests

## Adding Periodic Hyper-V Testing

To enable continuous Hyper-V testing in TestGrid, submit a PR to `kubernetes/test-infra` with the following changes:

### Step 1: Add Periodic Job

Add to `config/jobs/kubernetes-sigs/sig-windows/release-master-windows.yaml`:

```yaml
- name: ci-kubernetes-e2e-capz-master-windows-hyperv
  cluster: eks-prow-build-cluster
  interval: 24h  # Run once daily
  decorate: true
  decoration_config:
    timeout: 4h
  labels:
    preset-dind-enabled: "true"
    preset-kind-volume-mounts: "true"
    preset-capz-windows-common: "true"
    preset-capz-windows-2022: "true"
    preset-capz-containerd-2-0-latest: "true"
    preset-azure-community: "true"
  extra_refs:
  - org: kubernetes-sigs
    repo: cluster-api-provider-azure
    base_ref: main
    path_alias: sigs.k8s.io/cluster-api-provider-azure
    workdir: false
  - org: kubernetes-sigs
    repo: windows-testing
    base_ref: master
    path_alias: sigs.k8s.io/windows-testing
    workdir: true
  - org: kubernetes-sigs
    repo: cloud-provider-azure
    base_ref: master
    path_alias: sigs.k8s.io/cloud-provider-azure
    workdir: false
  spec:
    serviceAccountName: azure
    containers:
      - image: gcr.io/k8s-staging-test-infra/kubekins-e2e:v20260108-6ef4f0b08f-master
        command:
          - "runner.sh"
          - "env"
          - "KUBERNETES_VERSION=latest"
          - "./capz/run-capz-e2e.sh"
        env:
          - name: HYPERV
            value: "true"
          - name: GINKGO_FOCUS
            value: \[Feature:WindowsHyperVContainers\]
        securityContext:
          privileged: true
        resources:
          requests:
            cpu: 2
            memory: "9Gi"
          limits:
            cpu: 2
            memory: "9Gi"
  annotations:
    testgrid-alert-email: kubernetes-provider-azure@googlegroups.com, sig-windows-leads@kubernetes.io
    testgrid-dashboards: sig-windows-master-release, sig-windows-signal
    testgrid-tab-name: capz-windows-master-hyperv
```

### Step 2: (Optional) Add Dedicated TestGrid Dashboard

Add to `config/testgrids/kubernetes/sig-windows/config.yaml`:

```yaml
# Add to dashboard_groups.dashboard_names list:
dashboard_groups:
- name: sig-windows
  dashboard_names:
    # ... existing dashboards ...
    - sig-windows-hyperv  # Add this

# Add new dashboard definition:
dashboards:
# ... existing dashboards ...
- name: sig-windows-hyperv
  dashboard_tab:
  - name: capz-windows-master-hyperv
    description: Runs Windows Hyper-V container E2E tests on master branch K8s clusters
    test_group_name: k8s-e2e-windows-hyperv-master

# Add test group:
test_groups:
# ... existing test groups ...
- name: k8s-e2e-windows-hyperv-master
  gcs_prefix: kubernetes-sigs/logs/ci-kubernetes-e2e-capz-master-windows-hyperv
```

## Key Configuration Elements

| Element | Value | Purpose |
|---------|-------|---------|
| `HYPERV=true` | Environment variable | Enables Hyper-V isolation in CAPZ cluster |
| `GINKGO_FOCUS` | `\[Feature:WindowsHyperVContainers\]` | Targets Hyper-V specific tests |
| `interval` | `24h` | Daily test runs (adjust based on resource availability) |
| `preset-capz-windows-2022` | Label | Uses Windows Server 2022 (required for Hyper-V) |
| `testgrid-dashboards` | `sig-windows-signal` | Shows on signal dashboard for visibility |

## TestGrid Dashboard Structure

The sig-windows TestGrid configuration includes these dashboards:

| Dashboard | Purpose |
|-----------|---------|
| `sig-windows-signal` | Primary signal dashboard for Windows health |
| `sig-windows-master-release` | Master branch release tests |
| `sig-windows-presubmit` | PR presubmit tests |
| `sig-windows-networking` | Network-specific tests (Flannel, AzureCNI) |
| `sig-windows-gce` | GCE-specific Windows tests |

## Presets Used

The following presets are defined in `config/jobs/kubernetes-sigs/sig-windows/presets.yaml`:

- **`preset-capz-windows-common`**: Common CAPZ Windows settings (E2E_ARGS, WINDOWS=true, etc.)
- **`preset-capz-windows-2022`**: Windows Server 2022 configuration
- **`preset-capz-containerd-2-0-latest`**: Containerd 2.0 runtime
- **`preset-azure-community`**: Azure community subscription settings

## Repository References

The job clones these repositories:

| Repository | Branch | Purpose |
|------------|--------|---------|
| `kubernetes-sigs/cluster-api-provider-azure` | main | CAPZ for cluster provisioning |
| `kubernetes-sigs/windows-testing` | master | Test scripts and webhook |
| `kubernetes-sigs/cloud-provider-azure` | master | Azure cloud provider |

## Files to Modify

1. **Periodic Job:** `config/jobs/kubernetes-sigs/sig-windows/release-master-windows.yaml`
2. **TestGrid Config:** `config/testgrids/kubernetes/sig-windows/config.yaml`

## PR Process

1. Fork `kubernetes/test-infra`
2. Make changes to the files listed above
3. Run `make verify` to validate configuration
4. Submit PR with title like: `[sig-windows] Add periodic Hyper-V container e2e test job`
5. Request review from `@sig-windows-leads`

## Viewing Results

Once merged, results will appear at:
- **TestGrid:** https://testgrid.k8s.io/sig-windows-signal
- **Prow Jobs:** https://prow.k8s.io/?job=ci-kubernetes-e2e-capz-master-windows-hyperv

## Related Links

- [Kubernetes TestGrid](https://testgrid.k8s.io/sig-windows-signal)
- [Prow Job Configuration](https://github.com/kubernetes/test-infra/tree/master/config/jobs/kubernetes-sigs/sig-windows)
- [Windows Testing Repository](https://github.com/kubernetes-sigs/windows-testing)
- [Hyper-V Container Architecture](./hyperv-container-architecture.md)
