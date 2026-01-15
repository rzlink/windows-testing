# Kubernetes E2E Testing Guide for Beginners

A comprehensive guide for setting up a Kubernetes cluster on Azure and running E2E tests against it.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Environment Setup](#environment-setup)
3. [Creating a Cluster](#creating-a-cluster)
4. [Running E2E Tests](#running-e2e-tests)
5. [Debugging Tests in VS Code](#debugging-tests-in-vs-code)
6. [Running Tests from Command Line](#running-tests-from-command-line)
7. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Required Tools

Install the following tools before proceeding:

```bash
# Go (version 1.25.0 or later)
curl -LO https://go.dev/dl/go1.25.0.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.25.0.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin

# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# jq (JSON processor)
sudo apt-get install -y jq

# Delve debugger (for VS Code debugging)
go install github.com/go-delve/delve/cmd/dlv@latest
```

### Required GitHub Repositories

Clone these repositories in your workspace:

```bash
# Set up workspace directory
export GITHUB_WORKSPACE="${HOME}/github"
mkdir -p "$GITHUB_WORKSPACE"
cd "$GITHUB_WORKSPACE"

# 1. Windows Testing repo (main repo)
git clone https://github.com/kubernetes-sigs/windows-testing.git
cd windows-testing

# 2. Cluster API Provider Azure (CAPZ)
cd "$GITHUB_WORKSPACE"
git clone https://github.com/kubernetes-sigs/cluster-api-provider-azure.git

# 3. Cloud Provider Azure
cd "$GITHUB_WORKSPACE"
git clone https://github.com/kubernetes-sigs/cloud-provider-azure.git

# 4. Kubernetes (for E2E tests)
cd "$GITHUB_WORKSPACE/windows-testing"
git clone https://github.com/kubernetes/kubernetes.git
```

**Directory structure after cloning:**
```
~/github/
├── windows-testing/
│   ├── capz/
│   │   ├── env.sh
│   │   ├── run-capz-e2e.sh
│   │   └── ...
│   └── kubernetes/
│       └── test/e2e/
├── cluster-api-provider-azure/
└── cloud-provider-azure/
```

### Azure Prerequisites

1. **Azure Subscription**: You need an active Azure subscription
2. **Service Principal**: Create a service principal with Contributor role

```bash
# Login to Azure
az login

# Set your subscription
az account set --subscription "YOUR_SUBSCRIPTION_ID"

# Create service principal (save the output!)
az ad sp create-for-rbac --name "k8s-e2e-testing" --role Contributor \
  --scopes /subscriptions/YOUR_SUBSCRIPTION_ID
```

The output will look like:
```json
{
  "appId": "YOUR_CLIENT_ID",
  "password": "YOUR_CLIENT_SECRET",
  "tenant": "YOUR_TENANT_ID"
}
```

3. **Azure Storage Account** (optional, for presubmit tests):
   - Used to store built Kubernetes binaries
   - Can use existing account or create new one

4. **Set up Azure credentials for authentication**:

```bash
# Create credentials file for Azure
mkdir -p ~/.azure

# Login with service principal
az login --service-principal \
  -u YOUR_CLIENT_ID \
  -p YOUR_CLIENT_SECRET \
  --tenant YOUR_TENANT_ID

# Or set environment variables
export AZURE_CLIENT_ID="YOUR_CLIENT_ID"
export AZURE_CLIENT_SECRET="YOUR_CLIENT_SECRET"
export AZURE_TENANT_ID="YOUR_TENANT_ID"
export AZURE_SUBSCRIPTION_ID="YOUR_SUBSCRIPTION_ID"
```

---

## Environment Setup

### 1. Configure env.sh

Edit the `capz/env.sh` file to customize your cluster configuration:

```bash
cd ~/github/windows-testing/capz
vim env.sh  # or use your preferred editor
```

**Key configurations to update:**

```bash
# Kubernetes version to deploy
export KUBERNETES_VERSION="latest-1.35"

# Cluster size
export CONTROL_PLANE_MACHINE_COUNT="1"  # Number of control plane nodes
export WINDOWS_WORKER_MACHINE_COUNT="2" # Number of Windows worker nodes

# Windows version
export WINDOWS_SERVER_VERSION="windows-2022"  # or "windows-2019"

# Azure credentials (REQUIRED - update with your values)
export AZURE_SUBSCRIPTION_ID="YOUR_SUBSCRIPTION_ID"
export AZURE_CLIENT_ID="YOUR_CLIENT_ID"
export AZURE_TENANT_ID="YOUR_TENANT_ID"
export AZURE_LOCATION="eastus"  # Azure region

# Repository paths (update if different)
export AZURE_CLOUD_PROVIDER_ROOT="${HOME}/github/cloud-provider-azure"
export CAPZ_DIR="${HOME}/github/cluster-api-provider-azure"

# Optional features
export HYPERV="true"   # Enable Hyper-V isolated containers
export GMSA=""         # Enable GMSA (Group Managed Service Accounts)

# Cluster lifecycle control
export SKIP_CREATE=false   # Set to true if cluster already exists
export SKIP_TEST=false     # Set to true to skip E2E tests
export SKIP_CLEANUP=true   # Set to true to keep cluster after tests
```

### 2. Understanding env.sh Variables

| Variable                       | Description              | Default        | When to Change                |
| ------------------------------ | ------------------------ | -------------- | ----------------------------- |
| `KUBERNETES_VERSION`           | K8s version to deploy    | `latest-1.35`  | Testing specific K8s versions |
| `WINDOWS_WORKER_MACHINE_COUNT` | Number of Windows nodes  | `2`            | Need more/fewer nodes         |
| `HYPERV`                       | Enable Hyper-V isolation | `true`         | Testing Hyper-V features      |
| `SKIP_CREATE`                  | Skip cluster creation    | `false`        | Cluster already exists        |
| `SKIP_TEST`                    | Skip E2E tests           | `false`        | Only want to create cluster   |
| `SKIP_CLEANUP`                 | Keep cluster after tests | `true`         | Save costs (cleanup manually) |
| `CLUSTER_NAME`                 | Cluster name             | Auto-generated | Custom naming                 |

---

## Creating a Cluster

### Quick Start

```bash
cd ~/github/windows-testing/capz

# 1. Ensure env.sh is configured correctly
source ./env.sh

# 2. Verify Azure login
az account show

# 3. Run the script (creates cluster and runs tests)
./run-capz-e2e.sh
```

### Step-by-Step Process

The `run-capz-e2e.sh` script performs these steps:

#### 1. **Installs Required Tools**
   - Helm (Kubernetes package manager)
   - clusterctl (Cluster API CLI)
   
   These are installed to `capz/tools/bin/`

#### 2. **Sets Up Azure Environment**
   - Validates Azure credentials
   - Creates resource group
   - Sets up networking

#### 3. **Creates Kubernetes Cluster**
   - Deploys control plane (Linux)
   - Deploys Windows worker nodes
   - Configures networking (Calico CNI)
   - Installs cloud provider components

#### 4. **Applies Configurations**
   - Installs Calico networking
   - Deploys kube-proxy for Windows
   - Installs CSI proxy (for storage)
   - Configures Hyper-V runtime (if enabled)

#### 5. **Runs E2E Tests** (if not skipped)
   - Downloads test binaries
   - Executes conformance tests
   - Saves results to `_artifacts/` directory

### Manual Steps (If Needed)

#### Create Cluster Only (Skip Tests)

```bash
cd ~/github/windows-testing/capz
export SKIP_TEST=true
./run-capz-e2e.sh
```

#### Use Existing Cluster

```bash
cd ~/github/windows-testing/capz
export SKIP_CREATE=true
export KUBECONFIG=/path/to/your/kubeconfig
./run-capz-e2e.sh
```

#### Get Cluster Credentials

After cluster creation, the kubeconfig is saved as:
```bash
# Default location
export KUBECONFIG=~/github/windows-testing/capz/CLUSTER_NAME.kubeconfig

# Verify connection
kubectl get nodes
```

---

## Running E2E Tests

### Using run-capz-e2e.sh

The script automatically runs E2E tests with sensible defaults:

```bash
cd ~/github/windows-testing/capz
./run-capz-e2e.sh
```

**Default test configuration:**
- **Focus**: `[Conformance]|[NodeConformance]|[sig-windows]`
- **Skip**: `[LinuxOnly]|[Serial]|[Slow]|[Excluded:WindowsDocker]`
- **Parallel nodes**: 4
- **Results**: Saved to `_artifacts/` directory

### Custom Test Selection

Override test filters using environment variables:

```bash
# Run only sig-windows tests
export GINKGO_FOCUS="\[sig-windows\]"
export GINKGO_SKIP="\[LinuxOnly\]"
./run-capz-e2e.sh

# Run conformance tests serially
export RUN_SERIAL_TESTS=true
./run-capz-e2e.sh
```

### Manual E2E Test Execution

If you want more control, run tests manually:

```bash
cd ~/github/windows-testing/kubernetes

# 1. Build the E2E test binary
go test -c ./test/e2e -o e2e.test

# 2. Run specific tests
./e2e.test \
  --provider=skeleton \
  --kubeconfig=~/github/windows-testing/capz/YOUR_CLUSTER.kubeconfig \
  --node-os-distro=windows \
  --num-nodes=2 \
  --ginkgo.focus="pod generation should start at 1 and increment per update" \
  --ginkgo.v \
  -v=5

# 3. Run all conformance tests
./e2e.test \
  --provider=skeleton \
  --kubeconfig=~/github/windows-testing/capz/YOUR_CLUSTER.kubeconfig \
  --node-os-distro=windows \
  --num-nodes=2 \
  --ginkgo.focus="\[Conformance\]" \
  --ginkgo.skip="\[LinuxOnly\]|\[Serial\]" \
  --ginkgo.v \
  --report-dir=./_artifacts \
  -v=5
```

### Common Test Patterns

| Pattern           | Description                   |
| ----------------- | ----------------------------- |
| `\[Conformance\]` | All conformance tests         |
| `\[sig-windows\]` | Windows-specific tests        |
| `\[sig-node\]`    | Node-level tests              |
| `Pods Extended`   | Pod-related extended tests    |
| `pod generation`  | Pod generation specific tests |

### Common Skip Patterns

| Pattern         | Reason                                                |
| --------------- | ----------------------------------------------------- |
| `\[LinuxOnly\]` | Tests that only run on Linux                          |
| `\[Serial\]`    | Tests that must run serially (skip for parallel runs) |
| `\[Slow\]`      | Slow tests (skip for quick runs)                      |
| `\[Alpha\]`     | Alpha features (may be unstable)                      |

---

## Debugging Tests in VS Code

### Initial Setup

1. **Install VS Code Extensions**:
   - Go (by Go Team at Google)
   - Kubernetes (by Microsoft)

2. **Open the workspace**:
   ```bash
   cd ~/github/windows-testing
   code .
   ```

3. **Ensure Delve is installed**:
   ```bash
   # Install latest Delve
   go install github.com/go-delve/delve/cmd/dlv@latest
   
   # Verify installation
   ~/go/bin/dlv version
   ```

### Configure VS Code Debugger

Create/edit `.vscode/launch.json`:

```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Debug E2E Test - Pod Generation",
            "type": "go",
            "request": "launch",
            "mode": "auto",
            "program": "${workspaceFolder}/kubernetes/test/e2e/e2e_test.go",
            "env": {
                "KUBECONFIG": "${workspaceFolder}/capz/${input:clusterName}.kubeconfig"
            },
            "args": [
                "--provider", "skeleton",
                "--kubeconfig", "${workspaceFolder}/capz/${input:clusterName}.kubeconfig",
                "--node-os-distro", "windows",
                "--num-nodes", "2",
                "--ginkgo.trace",
                "--ginkgo.v",
                "--ginkgo.focus", "pod generation should start at 1 and increment per update",
                "--dump-logs-on-failure",
                "-v", "5"
            ]
        },
        {
            "name": "Debug E2E Test - Custom Focus",
            "type": "go",
            "request": "launch",
            "mode": "auto",
            "program": "${workspaceFolder}/kubernetes/test/e2e/e2e_test.go",
            "env": {
                "KUBECONFIG": "${workspaceFolder}/capz/${input:clusterName}.kubeconfig"
            },
            "args": [
                "--provider", "skeleton",
                "--kubeconfig", "${workspaceFolder}/capz/${input:clusterName}.kubeconfig",
                "--node-os-distro", "windows",
                "--num-nodes", "2",
                "--ginkgo.trace",
                "--ginkgo.v",
                "--ginkgo.focus", "${input:testFocus}",
                "--dump-logs-on-failure",
                "-v", "5"
            ]
        }
    ],
    "inputs": [
        {
            "id": "clusterName",
            "type": "promptString",
            "description": "Enter the cluster name (without .kubeconfig)",
            "default": "davwei-capz-hyperv-202601140112"
        },
        {
            "id": "testFocus",
            "type": "promptString",
            "description": "Enter the test name to focus on",
            "default": "pod generation"
        }
    ]
}
```

**Note**: VS Code will prompt you for the cluster name when you start debugging. The default value is set to the current cluster (`davwei-capz-hyperv-202601140112`), so you can simply press Enter or type a different cluster name.

### Using the Debugger

#### Method 1: Run and Debug Panel

1. Open the test file: `kubernetes/test/e2e/node/pods.go`
2. Set breakpoints by clicking left of line numbers
3. Press `F5` or click "Run and Debug" in left sidebar
4. Select "Debug E2E Test - Pod Generation"
5. Test will pause at breakpoints

#### Method 2: Debugging Specific Test

1. Open command palette: `Ctrl+Shift+P` (Linux/Windows) or `Cmd+Shift+P` (Mac)
2. Type: "Debug: Select and Start Debugging"
3. Choose "Debug E2E Test - Custom Focus"
4. Enter test name when prompted
5. Test will start with debugger attached

### Debugger Controls

| Action    | Shortcut        | Description                                   |
| --------- | --------------- | --------------------------------------------- |
| Continue  | `F5`            | Continue execution to next breakpoint         |
| Step Over | `F10`           | Execute current line, skip function internals |
| Step Into | `F11`           | Step into function calls                      |
| Step Out  | `Shift+F11`     | Step out of current function                  |
| Restart   | `Ctrl+Shift+F5` | Restart debugging session                     |
| Stop      | `Shift+F5`      | Stop debugging                                |

### Debugging Tips

1. **Set conditional breakpoints**: Right-click breakpoint → Edit Breakpoint → Add condition
2. **Watch variables**: Add variables to Watch panel (left sidebar during debug)
3. **Debug console**: Use Debug Console to evaluate expressions during debug session
4. **Log points**: Right-click line → Add Logpoint (logs without stopping)

### Common Debugging Scenarios

#### Debugging Test Failure

1. Set breakpoint at test function start
2. Step through test execution
3. Inspect pod objects, API responses
4. Check error messages in Variables panel

#### Debugging API Calls

1. Set breakpoint before API call
2. Step into `podClient.Update()` or similar
3. Inspect request/response objects
4. Check validation errors

---

## Running Tests from Command Line

### Quick Reference

```bash
cd ~/github/windows-testing/kubernetes

# Build once (only needed after code changes)
go test -c ./test/e2e -o e2e.test

# Run specific test
./e2e.test \
  --provider=skeleton \
  --kubeconfig=/path/to/kubeconfig \
  --node-os-distro=windows \
  --num-nodes=2 \
  --ginkgo.focus="YOUR_TEST_PATTERN" \
  --ginkgo.v \
  -v=5
```

### Detailed Examples

#### 1. Run Single Test

```bash
./e2e.test \
  --provider=skeleton \
  --kubeconfig=~/github/windows-testing/capz/YOUR_CLUSTER.kubeconfig \
  --node-os-distro=windows \
  --num-nodes=2 \
  --ginkgo.focus="pod generation should start at 1 and increment per update" \
  --ginkgo.v \
  --ginkgo.trace \
  -v=5
```

#### 2. Run All Pod Tests

```bash
./e2e.test \
  --provider=skeleton \
  --kubeconfig=~/github/windows-testing/capz/YOUR_CLUSTER.kubeconfig \
  --node-os-distro=windows \
  --num-nodes=2 \
  --ginkgo.focus="Pods Extended" \
  --ginkgo.skip="\[LinuxOnly\]" \
  --ginkgo.v \
  -v=5
```

#### 3. Run Conformance Tests

```bash
./e2e.test \
  --provider=skeleton \
  --kubeconfig=~/github/windows-testing/capz/YOUR_CLUSTER.kubeconfig \
  --node-os-distro=windows \
  --num-nodes=2 \
  --ginkgo.focus="\[Conformance\]" \
  --ginkgo.skip="\[LinuxOnly\]|\[Serial\]|\[Slow\]" \
  --report-dir=./_artifacts \
  --ginkgo.v \
  -v=5
```

#### 4. Dry Run (List Tests Without Running)

```bash
./e2e.test \
  --provider=skeleton \
  --kubeconfig=~/github/windows-testing/capz/YOUR_CLUSTER.kubeconfig \
  --node-os-distro=windows \
  --ginkgo.dryRun \
  --ginkgo.focus="Pods Extended"
```

#### 5. Run Tests in Parallel

```bash
# Install ginkgo CLI
go install github.com/onsi/ginkgo/v2/ginkgo@latest

# Run with 4 parallel nodes
~/go/bin/ginkgo --nodes=4 ./e2e.test -- \
  --provider=skeleton \
  --kubeconfig=~/github/windows-testing/capz/YOUR_CLUSTER.kubeconfig \
  --node-os-distro=windows \
  --num-nodes=2 \
  --ginkgo.focus="\[Conformance\]" \
  --ginkgo.skip="\[LinuxOnly\]|\[Serial\]" \
  -v=5
```

### Test Output Control

| Flag                     | Description                         |
| ------------------------ | ----------------------------------- |
| `--ginkgo.v`             | Verbose output (show all tests)     |
| `--ginkgo.trace`         | Show full stack trace on failure    |
| `--ginkgo.progress`      | Show progress during test run       |
| `--ginkgo.noColor`       | Disable colored output              |
| `-v=5`                   | Kubernetes logging verbosity (0-10) |
| `--report-dir=DIR`       | Save test results to directory      |
| `--dump-logs-on-failure` | Dump pod logs when test fails       |

### Rebuilding After Changes

```bash
# Quick rebuild and run
go test -c ./test/e2e -o e2e.test && \
./e2e.test \
  --provider=skeleton \
  --kubeconfig=~/github/windows-testing/capz/YOUR_CLUSTER.kubeconfig \
  --node-os-distro=windows \
  --num-nodes=2 \
  --ginkgo.focus="YOUR_TEST" \
  -v=5
```

---

## Troubleshooting

### Common Issues and Solutions

#### 1. "CAPZ_DIR not found" Error

**Symptom:**
```
Must have capz repo present
```

**Solution:**
```bash
cd ~/github
git clone https://github.com/kubernetes-sigs/cluster-api-provider-azure.git
```

Update `env.sh`:
```bash
export CAPZ_DIR="${HOME}/github/cluster-api-provider-azure"
```

#### 2. "cloud-provider-azure repo not found"

**Solution:**
```bash
cd ~/github
git clone https://github.com/kubernetes-sigs/cloud-provider-azure.git
```

Update `env.sh`:
```bash
export AZURE_CLOUD_PROVIDER_ROOT="${HOME}/github/cloud-provider-azure"
```

#### 3. Azure Authentication Failures

**Symptoms:**
- "Unauthorized" errors
- "Invalid credentials"

**Solution:**
```bash
# Re-login to Azure
az login

# Verify credentials
az account show

# Check service principal
az ad sp show --id YOUR_CLIENT_ID

# Set environment variables
export AZURE_CLIENT_ID="YOUR_CLIENT_ID"
export AZURE_CLIENT_SECRET="YOUR_CLIENT_SECRET"
export AZURE_TENANT_ID="YOUR_TENANT_ID"
```

#### 4. Cluster Creation Timeout

**Symptoms:**
- Script hangs waiting for nodes
- Nodes stuck in "NotReady" state

**Solutions:**
```bash
# Check cluster status
kubectl get nodes -o wide
kubectl get pods -A

# Check machine provisioning (requires management cluster access)
kubectl get machines -A
kubectl get azuremachines -A

# Check logs
kubectl logs -n kube-system -l component=kube-apiserver
```

#### 5. Test Binary Build Failures

**Symptom:**
```
go: cannot find main module
```

**Solution:**
```bash
# Ensure you're in kubernetes directory
cd ~/github/windows-testing/kubernetes

# Verify go.mod exists
ls go.mod

# If missing, you're in wrong directory
cd ~/github/windows-testing/kubernetes  # Try again
```

#### 6. Delve DWARFv5 Error

**Symptom:**
```
to debug executables using DWARFv5 or later Delve must be built with go version 1.25.0
```

**Solution:**
```bash
# Upgrade Go
curl -LO https://go.dev/dl/go1.25.0.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.25.0.linux-amd64.tar.gz

# Rebuild Delve
go install github.com/go-delve/delve/cmd/dlv@latest

# Verify
~/go/bin/dlv version
```

#### 7. Test Failures Due to Code Issues

**Symptom:**
- Test fails with validation errors
- Unexpected API rejections

**Common causes:**
1. Test code violates K8s API validation rules
2. API version incompatibility
3. Test assumptions don't match cluster state

**Debug approach:**
1. Enable debug mode: `-v=5`
2. Check full error message
3. Set breakpoint before failing operation
4. Inspect API request/response

#### 8. Kubeconfig Not Found

**Symptom:**
```
error: unable to read client-cert /path/to/cert: open /path/to/cert: no such file or directory
```

**Solution:**
```bash
# List available kubeconfigs
ls ~/github/windows-testing/capz/*.kubeconfig

# Use full path in commands
export KUBECONFIG=~/github/windows-testing/capz/YOUR_CLUSTER.kubeconfig

# Test connection
kubectl get nodes
```

### Cleanup Resources

#### Manual Cluster Cleanup

```bash
# Get cluster name
az group list --query "[?starts_with(name, 'davwei-capz')].name" -o tsv

# Delete resource group
az group delete --name CLUSTER_NAME --yes --no-wait

# Verify deletion
az group list --query "[?starts_with(name, 'davwei-capz')].name" -o tsv
```

#### Clean Local Artifacts

```bash
cd ~/github/windows-testing
rm -rf _artifacts/
rm -rf kubernetes/e2e.test
rm -rf capz/*.kubeconfig
```

### Getting Help

1. **Check script logs**: Full output is in terminal
2. **Kubernetes logs**: `kubectl logs -n kube-system POD_NAME`
3. **Azure portal**: Check resource provisioning status
4. **Community support**:
   - Kubernetes Slack: #sig-windows, #sig-testing
   - GitHub Issues: kubernetes/kubernetes, kubernetes-sigs/windows-testing

---

## Workflow Examples

### Complete Test Cycle

```bash
# 1. Set up environment
cd ~/github/windows-testing/capz
vim env.sh  # Configure your settings

# 2. Create cluster and run all tests
./run-capz-e2e.sh

# 3. After tests complete, run additional manual tests
cd ~/github/windows-testing/kubernetes
go test -c ./test/e2e -o e2e.test

./e2e.test \
  --provider=skeleton \
  --kubeconfig=~/github/windows-testing/capz/LATEST_CLUSTER.kubeconfig \
  --node-os-distro=windows \
  --num-nodes=2 \
  --ginkgo.focus="YOUR_SPECIFIC_TEST" \
  -v=5

# 4. Debug failing test in VS Code
code ~/github/windows-testing
# Open test file, set breakpoints, press F5

# 5. Cleanup
export CLUSTER_NAME=$(ls ~/github/windows-testing/capz/*.kubeconfig | head -1 | xargs basename | sed 's/.kubeconfig//')
az group delete --name $CLUSTER_NAME --yes
```

### Development Workflow

```bash
# 1. Make changes to test code
vim ~/github/windows-testing/kubernetes/test/e2e/node/pods.go

# 2. Rebuild test binary
cd ~/github/windows-testing/kubernetes
go test -c ./test/e2e -o e2e.test

# 3. Run modified test
./e2e.test \
  --provider=skeleton \
  --kubeconfig=~/github/windows-testing/capz/YOUR_CLUSTER.kubeconfig \
  --node-os-distro=windows \
  --num-nodes=2 \
  --ginkgo.focus="YOUR_MODIFIED_TEST" \
  -v=5

# 4. Iterate until test passes
# Repeat steps 1-3

# 5. Run full test suite to ensure no regressions
./run-capz-e2e.sh
```

---

## Advanced Topics

### Running Specific Test Suites

```bash
# Node conformance only
export GINKGO_FOCUS="\[NodeConformance\]"
./run-capz-e2e.sh

# Serial tests only
export RUN_SERIAL_TESTS=true
./run-capz-e2e.sh

# Sig-windows tests only
export GINKGO_FOCUS="\[sig-windows\]"
export GINKGO_SKIP="\[LinuxOnly\]"
./run-capz-e2e.sh
```

### Using Pre-built Test Binaries

```bash
# Download pre-built test binaries
CI_VERSION="v1.35.0"
curl -L -o /tmp/kubernetes-test-linux-amd64.tar.gz \
  "https://storage.googleapis.com/k8s-release-dev/ci/${CI_VERSION}/kubernetes-test-linux-amd64.tar.gz"

tar -xzvf /tmp/kubernetes-test-linux-amd64.tar.gz

# Use downloaded binaries
./kubernetes/test/bin/e2e.test --help
```

### Custom Test Filters

Use regex patterns for precise test selection:

```bash
# All pod-related tests
--ginkgo.focus="pod|Pod"

# Generation tests only
--ginkgo.focus="generation"

# Multiple patterns (OR)
--ginkgo.focus="pod.*generation|container.*lifecycle"

# Negative patterns (skip)
--ginkgo.skip="Serial|Slow|Flaky"
```

---

## Quick Reference Card

### Essential Commands

```bash
# Create cluster
cd ~/github/windows-testing/capz && ./run-capz-e2e.sh

# Get cluster info
kubectl --kubeconfig=~/github/windows-testing/capz/CLUSTER.kubeconfig get nodes

# Build test binary
cd ~/github/windows-testing/kubernetes && go test -c ./test/e2e -o e2e.test

# Run test
./e2e.test --provider=skeleton --kubeconfig=PATH --ginkgo.focus="TEST"

# Debug in VS Code
# Open workspace, set breakpoints, press F5

# Cleanup
az group delete --name CLUSTER_NAME --yes
```

### Key Files

| File                   | Purpose                    |
| ---------------------- | -------------------------- |
| `capz/env.sh`          | Cluster configuration      |
| `capz/run-capz-e2e.sh` | Main automation script     |
| `.vscode/launch.json`  | VS Code debug config       |
| `_artifacts/`          | Test results directory     |
| `*.kubeconfig`         | Cluster access credentials |

### Important Environment Variables

| Variable       | Description                 |
| -------------- | --------------------------- |
| `KUBECONFIG`   | Path to cluster credentials |
| `GINKGO_FOCUS` | Test filter (include)       |
| `GINKGO_SKIP`  | Test filter (exclude)       |
| `SKIP_CREATE`  | Skip cluster creation       |
| `SKIP_TEST`    | Skip running tests          |
| `SKIP_CLEANUP` | Keep cluster after tests    |

---

## Appendix: Script Analysis

### run-capz-e2e.sh Prerequisites

**Required before running:**
1. ✅ GOPATH set (Go installed)
2. ✅ Azure CLI installed and authenticated
3. ✅ `cluster-api-provider-azure` repo cloned
4. ✅ `cloud-provider-azure` repo cloned
5. ✅ `env.sh` configured with Azure credentials
6. ✅ Network access to Azure
7. ✅ Kubernetes repo cloned (for tests)

**Script will automatically:**
1. ✅ Install helm
2. ✅ Install clusterctl
3. ✅ Create Azure resource groups
4. ✅ Deploy Kubernetes cluster
5. ✅ Configure networking (Calico)
6. ✅ Install cloud provider components
7. ✅ Download test binaries (or use local build)
8. ✅ Run E2E tests
9. ✅ Collect results to `_artifacts/`

**Optional manual steps:**
- Pre-build Kubernetes binaries (for faster testing)
- Set up GMSA domain controller (if testing GMSA)
- Configure private registry access (for some tests)

---

**Document Version:** 1.0  
**Last Updated:** January 9, 2026  
**Tested With:** Kubernetes 1.35, Go 1.25.0, Ubuntu 24.04
