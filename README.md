# NVIDIA + MicroShift bootc

## Which branch?

| Branch | Role |
|--------|------|
| **`rhel96-ga`** | **RHEL 9.6 line** (created from **`main`**): RHEL **9.6** GA + MicroShift **4.20** with **proprietary / precompiled** NVIDIA kmod (**`Containerfile.builder`**, self-signed MOK, CUDA from NVIDIA public repos). |
| **`rhel10_ushift421_nvidia_oss_tp`** | **Current validated line**: RHEL **10.2** + MicroShift **4.21** + **Red Hat–signed OSS (OpenRM) NVIDIA drivers** via `rhel-drivers` (Extensions + Supplementary). Single `Containerfile`, no precompiled kmod, no self-signed MOK. The **`_tp`** suffix marks the **MicroShift + RHEL 10** pairing as Tech Preview; the RHEL 10.1+ OSS NVIDIA drivers are **GA**. Validated on Azure Standard NC4as T4 v3 with Secure Boot enabled. |

**This checkout:** you are on **`rhel10_ushift421_nvidia_oss_tp`**. Use **`argfile.conf`** (`SINGLE_STAGE_BOOTC=1`) and **`./test-build.sh`**. No builder image or kmod signing step is required.

---

## What this image contains

A fully self-contained [image mode for RHEL](https://docs.redhat.com/en/documentation/red_hat_build_of_microshift/4.21/html-single/installing_with_image_mode_for_rhel/index) bootc image with:

- **RHEL 10.2 bootc** base (`registry.redhat.io/rhel10/rhel-bootc:10.2`)
- **NVIDIA OSS driver 595.71.05** — installed via `rhel-drivers install nvidia` from Red Hat Extensions + Supplementary repos. `kmod-nvidia-open` is pre-signed by the **Nvidia GPU OOT CA**; no self-signed MOK required.
- **Nouveau blacklisted at initramfs level** — `etc/dracut.conf.d/99-blacklist-nouveau.conf` and `99-nvidia-early.conf` bake the blacklist and NVIDIA modules into the initramfs via `bootc-image-builder`'s dracut pass, eliminating the nouveau/nvidia race at boot.
- **Red Hat build of MicroShift 4.21** — container images physically embedded under `/usr/lib/containers/storage` (disconnected-friendly flow).
- **NVIDIA Kubernetes Device Plugin** — static manifests under `/etc/microshift/manifests.d/nvidia-device-plugin/`; `NVDP_IMAGE` is embedded so air-gapped nodes do not pull at runtime.
- **CRI-O + NVIDIA Container Toolkit** — `nvidia-ctk runtime configure` for CRI-O, MicroShift drop-in ordering, `container_use_devices` SELinux boolean.
- **WALinuxAgent + cloud-init** — Azure VM provisioning (SSH key injection, disk resize, Azure metadata). Required for Azure VHD deployments; not needed for ISO/bare-metal targets (see [Platform notes](#platform-notes)).

> **Disclaimer:** Builds and runtime behavior have been validated on **x86\_64** only. **aarch64** and other architectures are not validated.

---

## Secure Boot

**No MOK enrollment required.** The `Nvidia GPU OOT signing 001` certificate is built into the RHEL 10 kernel's trusted keyring. NVIDIA OSS modules load automatically under Secure Boot without any manual key enrollment step. This is a significant advantage over the RHEL 9.6 proprietary path which required self-signed MOK management.

Validated result with Secure Boot enabled (Azure Trusted Launch Gen2 VM):

```
SecureBoot enabled
Loaded X.509 cert 'Nvidia GPU OOT signing 001: 55e1cef88193e60419f0b0ec379c49f77545acf0'
nvidia, nvidia_uvm, nvidia_modeset, nvidia_drm  ← all loaded, no MOK prompt
```

To enable Trusted Launch on a new Azure VM, use an **Azure Compute Gallery** image definition with `SecurityType=TrustedLaunchSupported`. The classic `Microsoft.Compute/images` resource type does not support Trusted Launch via `az image create`. See [Trusted Launch FAQ](https://aka.ms/TrustedLaunch-FAQ).

---

## Known issue fixed: nouveau vs nvidia boot conflict

On GPU SKUs (Azure N-series), earlier builds booted into an infinite kernel log loop:

```
NVRM: GPU 0001:00:00.0 is already bound to nouveau
NVRM: No NVIDIA devices probed
```

**Root cause:** The initramfs did not contain the nouveau blacklist. The nouveau driver loaded during early boot before the root filesystem was mounted, claimed the GPU via udev, and the NVIDIA driver found nothing to attach to when it loaded later from `/etc/modules-load.d/`.

**Fix — two dracut drop-in files consumed by `bootc-image-builder`:**

`etc/dracut.conf.d/99-blacklist-nouveau.conf`:
```
omit_drivers+=" nouveau "
install_items+=" /etc/modprobe.d/blacklist_nouveau.conf "
```

`etc/dracut.conf.d/99-nvidia-early.conf`:
```
force_drivers+=" nvidia nvidia-uvm nvidia-drm nvidia-modeset "
```

`bootc-image-builder` runs dracut in its privileged disk-assembly environment and picks up these confs automatically via `COPY etc /etc` in the Containerfile. **Do not add `dracut --force` inside the install script** — dracut cannot run inside a container build environment (no running kernel, no `/proc/modules`).

The nouveau blacklist is also written **before** `rhel-drivers install` runs in `scripts/image/install-microshift-nvidia-oss-rhel10.sh` so it is present on the filesystem if `rhel-drivers` triggers any internal dracut invocation during driver installation.

---

## Prerequisites

- **Build host**: RHEL 10 (preferred) or RHEL 9 with an active Red Hat subscription. The following repos must be enabled on the host (mounted into the build via `BUILD_WITH_HOST_RHSM=1` + `BUILD_WITH_HOST_YUM_REPOS=1`):
  - `rhel-10-for-x86_64-baseos-rpms`
  - `rhel-10-for-x86_64-appstream-rpms`
  - `rhel-10-for-x86_64-supplementary-rpms`
  - `rhel-10-for-x86_64-extensions-rpms`
  - `rhocp-4.21-for-rhel-10-x86_64-rpms`
  - `fast-datapath-for-rhel-10-x86_64-rpms`
  - NVIDIA CUDA + container toolkit repos (created automatically by `scripts/host/configure-host-nvidia-build-repos.sh` when `CONFIGURE_HOST_NVIDIA_REPOS=1`)

- **Tools**: `podman` with `--secret` support, `bootc-image-builder` (for VHD/disk), Azure CLI (for Azure upload).

- **Pull secret**: Full OpenShift pull secret from [console.redhat.com/openshift/downloads](https://console.redhat.com/openshift/downloads#tool-pull-secret) — must include `registry.redhat.io` and `quay.io`. Place at `.pull-secret.json` in the repo root (**never commit this file**; it is listed in `.gitignore`).

- **Azure credentials**: Copy `cloud/azure/.env.azure.example` to `cloud/azure/.env.azure`, fill in `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, and optionally `AZURE_SUBSCRIPTION` / `AZURE_RESOURCE_GROUP`. Run `chmod 600 cloud/azure/.env.azure`. **Never commit this file** (listed in `.gitignore`). Rotate the client secret if it was ever shared.

---

## Quick start (build → VHD → Azure)

### 1. Configure

Edit `argfile.conf` — at minimum set `USER_PASSWD`. Review `BASE_IMAGE`, `USHIFT_VER`, `NVDP_IMAGE`.

Key settings for this branch:
```bash
SINGLE_STAGE_BOOTC=1
RHEL_MAJOR=10
BASE_IMAGE=registry.redhat.io/rhel10/rhel-bootc:10.2
BUILD_WITH_HOST_RHSM=1
BUILD_WITH_HOST_YUM_REPOS=1
USHIFT_VER=4.21
```

### 2. Build the bootc OCI image

```bash
chmod +x test-build.sh
./test-build.sh
```

`test-build.sh` delegates to `build/test-build.sh`. With `SINGLE_STAGE_BOOTC=1` it skips `Containerfile.builder` entirely (no precompiled kmod step) and builds only the single `Containerfile`. The pull secret at `.pull-secret.json` is resolved automatically.

Tag produced: `localhost/microshift-nvidia-bootc-test:latest` (override with `FINAL_IMAGE_TAG`).

Use **`sudo podman`** throughout if you will run `bootc-image-builder` with `sudo` in step 4, so the image store matches.

### 3. Validate the image before building the disk

Run these checks before investing time in a VHD build:

```bash
# Dracut confs present
sudo podman run --rm localhost/microshift-nvidia-bootc-test:latest \
  cat /etc/dracut.conf.d/99-blacklist-nouveau.conf

sudo podman run --rm localhost/microshift-nvidia-bootc-test:latest \
  cat /etc/dracut.conf.d/99-nvidia-early.conf

# Nouveau blacklisted
sudo podman run --rm localhost/microshift-nvidia-bootc-test:latest \
  cat /etc/modprobe.d/blacklist_nouveau.conf

# Kernel and kmod-nvidia-open version must match exactly
sudo podman run --rm localhost/microshift-nvidia-bootc-test:latest \
  bash -c "rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' && \
           rpm -qa | grep -E 'kmod-nvidia|nvidia-driver'"

# nvidia.ko must exist for the installed kernel
sudo podman run --rm localhost/microshift-nvidia-bootc-test:latest \
  bash -c "KVER=\$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}') && \
           find /lib/modules/\${KVER} -name 'nvidia.ko' 2>/dev/null"

# Built-in verify script
sudo podman run --rm localhost/microshift-nvidia-bootc-test:latest \
  /usr/bin/verify-nvidia-kmod.sh
```

All checks must pass before proceeding.

### 4. Produce a VHD

```bash
chmod +x build-bootc-disk.sh
sudo ./build-bootc-disk.sh -t vhd -o ./bib-output \
  localhost/microshift-nvidia-bootc-test:latest
find bib-output -name '*.vhd'
```

`bootc-image-builder` runs dracut during disk assembly and picks up the `etc/dracut.conf.d/` drop-ins automatically. This is when the nouveau blacklist and NVIDIA modules are baked into the initramfs.

Optionally pin the digest to avoid floating `latest`:
```bash
DIGEST=$(sudo podman inspect localhost/microshift-nvidia-bootc-test:latest \
  --format '{{.Digest}}')
sudo ./build-bootc-disk.sh -t vhd -o ./bib-output \
  "localhost/microshift-nvidia-bootc-test@${DIGEST}"
```

### 5. Upload to Azure

```bash
source cloud/azure/.env.azure
./azure-login-sp.sh

chmod +x cloud/azure/push-vhd-to-azure.sh

# Dry run first
./cloud/azure/push-vhd-to-azure.sh --dry-run \
  --vhd ./bib-output/vpc/disk.vhd \
  --resource-group myRg --storage-account mystore \
  --location eastus --image-name myMicroshiftNvidiaImage

# Actual upload
./cloud/azure/push-vhd-to-azure.sh \
  --vhd ./bib-output/vpc/disk.vhd \
  --resource-group myRg --storage-account mystore \
  --location eastus --image-name myMicroshiftNvidiaImage
```

The managed image is created as Gen2 (`--hyper-v-generation V2`). For Trusted Launch / Secure Boot support, use an **Azure Compute Gallery** image definition — `az image create` does not support `SecurityType=TrustedLaunchSupported` directly.

### 6. Deploy a VM

Use the portal or `az vm create`. Select a GPU size (e.g. `Standard_NC4as_T4_v3` for Tesla T4). Use the same region as the managed image.

For **Trusted Launch** (Secure Boot + vTPM): create the image as a Compute Gallery image version, then select **Security type: Trusted Launch** when creating the VM.

---

## Post-deployment validation

SSH in as user `redhat` (password from `USER_PASSWD`).

### Host and driver
```bash
# Secure Boot state
mokutil --sb-state

# NVIDIA modules loaded, nouveau absent
lsmod | grep -E 'nvidia|nouveau'

# Module signing — should show 'Nvidia GPU OOT signing 001'
modinfo nvidia | grep signer

# GPU visible
nvidia-smi
```

### MicroShift
```bash
oc get pods -A

oc get node -o jsonpath='{.items[0].status.allocatable}' | \
  python3 -m json.tool | grep nvidia
# Expected: "nvidia.com/gpu": "1"
```

### CDI generation
```bash
systemctl status nvidia-toolkit-firstboot.service
# Expected: active (exited), status=0/SUCCESS
```

### End-to-end GPU workload
```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: cuda-vectoradd
    image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubi8
    resources:
      limits:
        nvidia.com/gpu: "1"
EOF

oc get pod cuda-vectoradd -w
oc logs cuda-vectoradd
# Expected:
# Test PASSED
# Done
```

### Validated results (Azure Standard NC4as T4 v3 — RHEL 10.2, MicroShift 4.21.16, driver 595.71.05)

| Check | Without Secure Boot | With Secure Boot (Trusted Launch) |
|---|---|---|
| `nvidia-smi` | ✅ Tesla T4, 16GB | ✅ Tesla T4, 16GB |
| nvidia modules loaded | ✅ | ✅ |
| nouveau absent | ✅ | ✅ |
| MOK enrollment needed | N/A | ✅ Not required |
| `nvidia.com/gpu: 1` | ✅ | ✅ |
| nvidia-device-plugin | ✅ Running | ✅ Running |
| CUDA vectoradd | ✅ Test PASSED | ✅ Test PASSED |

---

## `argfile.conf` reference (this branch)

| Variable | Role |
|---|---|
| `SINGLE_STAGE_BOOTC` | Must be `1` — skips `Containerfile.builder` |
| `RHEL_MAJOR` | `10` |
| `BASE_IMAGE` | `registry.redhat.io/rhel10/rhel-bootc:10.2` |
| `BUILD_WITH_HOST_RHSM` | `1` — mounts `/etc/rhsm` and `/etc/pki/entitlement` into build |
| `BUILD_WITH_HOST_YUM_REPOS` | `1` — mounts `/etc/yum.repos.d` read-only; required for `rhocp-4.21-for-rhel-10-*` repos |
| `USHIFT_VER` | `4.21` |
| `DRIVER_TYPE` | `passthrough` |
| `USER_PASSWD` | **Required** — password for local user `redhat` |
| `NVDP_IMAGE` | NVIDIA device-plugin image to embed (default `nvcr.io/nvidia/k8s-device-plugin:v0.16.2`) |
| `CONFIGURE_BUILD_HOST_EUS` | `0` on this branch (RHEL 10, no EUS needed) |
| `CONFIGURE_HOST_NVIDIA_REPOS` | Default `1` — creates CUDA + toolkit `.repo` files on the host before the `yum.repos.d` bind mount |
| `CONFIGURE_HOST_MICROSHIFT_REPOS` | Default `1` — enables `rhocp-4.21-for-rhel-10-*` and `fast-datapath-for-rhel-10-*` on the host |

---

## Platform notes

### WALinuxAgent

WALinuxAgent is installed and enabled by default. It handles Azure-specific VM provisioning: SSH key injection, disk resize scripts, and Azure Monitor communication. **Required for Azure VHD deployments.**

For non-Azure targets, adapt `scripts/image/install-microshift-nvidia-oss-rhel10.sh` by removing the `WALinuxAgent` install line and the `systemctl enable waagent` and `cloud-init.target` lines.

| Target | WALinuxAgent | cloud-init |
|---|---|---|
| Azure VM (VHD) | ✅ Required | ✅ Required |
| ISO / bare metal | ❌ Remove | ❌ Optional |
| AWS AMI | ❌ Remove | ✅ Keep |
| KVM / qcow2 | ❌ Remove | ❌ Optional |

### ISO / bare metal

```bash
sudo ./build-bootc-disk.sh -t anaconda-iso -o ./bib-output \
  localhost/microshift-nvidia-bootc-test:latest
```

The NVIDIA dracut fixes apply equally — the initramfs baked into the ISO will contain the nouveau blacklist and NVIDIA modules.

---

## Troubleshooting

### nouveau vs nvidia loop at boot

**Symptom:** Serial console shows repeated:
```
NVRM: GPU 0001:00:00.0 is already bound to nouveau
NVRM: No NVIDIA devices probed
```

**Cause:** `etc/dracut.conf.d/` files were not present in the image when `bootc-image-builder` ran.

**Check:**
```bash
sudo podman run --rm localhost/microshift-nvidia-bootc-test:latest \
  cat /etc/dracut.conf.d/99-blacklist-nouveau.conf
```

### `rd.driver.pre` FATAL warnings in journalctl

**Symptom:**
```
dracut-pre-udev: modprobe: FATAL: Module nvidia not found in directory /lib/modules/...
```

**Cause:** `force_drivers` adds `rd.driver.pre=` kernel cmdline entries that fire early before the extra modules path is available. The modules still load correctly from the root filesystem. This is a cosmetic warning — all four NVIDIA modules load and `nvidia-smi` works.

### `kmod-nvidia-open` version mismatch

```bash
sudo podman run --rm localhost/microshift-nvidia-bootc-test:latest \
  bash -c "rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n'; \
           rpm -qa | grep kmod-nvidia"
# Both versions must match
```

If mismatched, rebuild the image so both resolve from the same repo metadata snapshot.

### Secure Boot: module blocked

If `journalctl -b | grep -i "verification failed"` shows NVIDIA modules blocked, extract and enroll the NVIDIA OOT CA cert:

```bash
KVER=$(uname -r)
KO=/lib/modules/${KVER}/extra/drivers/video/nvidia/nvidia.ko
/usr/src/kernels/${KVER}/scripts/sign-file --extract-cert ${KO} \
  > /tmp/nvidia-oot-ca.der
sudo mokutil --import /tmp/nvidia-oot-ca.der
# Reboot → MOK manager → Enroll Key → reboot
```

This should not be needed on RHEL 10.1+ (cert is in the kernel keyring), but may be required on older minor releases.

---

## Supportability

| Component | Status |
|---|---|
| RHEL 10.2 | GA |
| NVIDIA OSS drivers (`kmod-nvidia-open`) via `rhel-drivers` on RHEL 10.1+ | GA |
| MicroShift 4.21 on RHEL 10 | **Tech Preview** |
| MicroShift 4.21 + RHEL 10 for production | Requires Support Exception — contact your Red Hat TAM |

A Support Exception is required for production use of the MicroShift + RHEL 10 combination until MicroShift 5.2 GA. To initiate the exception process, provide a `sosreport` from the RHEL 10 host and `oc adm inspect ns/nvidia-device-plugin` output to your Red Hat TAM.

---

## Repository layout

```
.
├── Containerfile                          # Single-stage bootc image (RHEL 10 OSS path)
├── argfile.conf                           # Build knobs — edit before building
├── test-build.sh                          # Wrapper → build/test-build.sh
├── build-bootc-disk.sh                    # Wrapper → build/build-bootc-disk.sh
├── build/
│   ├── test-build.sh                      # OCI image build logic
│   └── build-bootc-disk.sh                # bootc-image-builder wrapper
├── cloud/azure/
│   ├── push-vhd-to-azure.sh               # VHD upload + managed image creation
│   ├── .env.azure.example                 # Azure credential template (copy, never commit)
│   └── azure-login-sp.sh                  # Service principal login helper
├── etc/
│   ├── dracut.conf.d/
│   │   ├── 99-blacklist-nouveau.conf      # Bakes nouveau blacklist into initramfs ← NEW
│   │   └── 99-nvidia-early.conf           # Forces NVIDIA modules into initramfs   ← NEW
│   ├── modprobe.d/
│   │   └── blacklist_nouveau.conf         # nouveau blacklist (also copied into initramfs)
│   ├── modules-load.d/
│   │   └── nvidia.conf                    # Loads nvidia + nvidia-uvm at boot
│   └── systemd/system/
│       └── nvidia-toolkit-firstboot.service  # CDI generation after modules settle
├── scripts/
│   ├── host/                              # Host prep scripts (repos, RHSM)
│   └── image/
│       ├── install-microshift-nvidia-oss-rhel10.sh   # Main install script
│       ├── enable-rhel10-nvidia-repos.sh
│       ├── verify-nvidia-kmod.sh          # Pre-disk-build kmod sanity check
│       └── embed-microshift-images.sh
└── validation/                            # Reference configs and smoke test artifacts
```

Files **never to commit**: `.pull-secret.json`, `cloud/azure/.env.azure` (both in `.gitignore`).
