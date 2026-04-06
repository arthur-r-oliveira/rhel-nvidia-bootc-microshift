# NVIDIA + MicroShift bootc image (RHEL 9.6)

**Branch: `feature/rhel96-microshift-nvidia-bootc`**

> **Disclaimer:** This repository is **work in progress**. Builds and runtime behavior have been exercised only on **x86_64**; **aarch64** and other architectures are not validated here.

## Quick start (build → VHD → Azure)

Minimal path on a subscribed **RHEL 9 x86_64** host with **Podman**. For the Azure step you also need the **Azure CLI** and a signed-in context (**`az login`** or a service principal).

**Azure lab / service principal credentials:** Store **client ID, client secret, tenant, and subscription** only in a **local file that is never committed**. Copy **`cloud/azure/.env.azure.example`** to **`cloud/azure/.env.azure`**, fill in **`AZURE_CLIENT_ID`**, **`AZURE_CLIENT_SECRET`**, **`AZURE_TENANT_ID`**, and optionally **`AZURE_SUBSCRIPTION`** / **`AZURE_RESOURCE_GROUP`** (the example maps names like **`CLIENT_ID`** → **`AZURE_CLIENT_ID`**; use **`AZURE_CLIENT_SECRET`**, not a generic **`PASSWORD`** export). Run **`chmod 600 cloud/azure/.env.azure`**, then **`./azure-login-sp.sh`** to run **`az login --service-principal`** and select the subscription. Override the file path with **`AZURE_ENV_FILE`** if needed. **Rotate the client secret** if it was ever pasted into chat, email, or a ticket. Do **not** put these values in **`argfile.conf`** or shell history-friendly **`export PASSWORD=...`** lines.

1. **Clone and configure** — Check out this repository, edit **`argfile.conf`** (at least **`USER_PASSWD`**; review **`BASE_IMAGE`**, **`BUILDER_IMAGE`**, **`DRIVER_VERSION`**, **`CUDA_VERSION`**, **`NVDP_IMAGE`**), and add the **full** OpenShift pull secret as **`.pull-secret.json`** in the repo root ([download](https://console.redhat.com/openshift/downloads#tool-pull-secret) — must include **`quay.io`** for embedded MicroShift images).

2. **Build the bootc OCI image** — From the repo root (use **`sudo podman`** for the whole pipeline if you will run BIB with **`sudo`** in step 3, so the image store matches):

   ```bash
   chmod +x test-build.sh
   ./test-build.sh
   ```

   By default this tags **`localhost/microshift-nvidia-bootc-test:latest`** (set **`FINAL_IMAGE_TAG`** when invoking **`test-build.sh`** if you need another name).

3. **Produce a VHD** with [bootc-image-builder](https://osbuild.org/docs/bootc/#-image-types):

   ```bash
   chmod +x build-bootc-disk.sh
   sudo ./build-bootc-disk.sh -t vhd -o ./bib-output localhost/microshift-nvidia-bootc-test:latest
   find bib-output -name '*.vhd'
   ```

   The **`.vhd`** path is often **`bib-output/vpc/disk.vhd`** or **`bib-output/vhd/disk.vhd`**. Optionally pass **`localhost/microshift-nvidia-bootc-test@sha256:…`** instead of **`:latest`** to pin the digest (see **Disk images** below).

4. **Upload to Azure** — Replace **`myRg`**, **`mystore`**, **`eastus`**, and **`myMicroshiftNvidiaImage`** with your resource group, storage account, region, and image name:

   ```bash
   chmod +x push-vhd-to-azure.sh
   ./push-vhd-to-azure.sh --dry-run \
     --vhd ./bib-output/vpc/disk.vhd \
     --resource-group myRg --storage-account mystore --location eastus \
     --image-name myMicroshiftNvidiaImage
   ./push-vhd-to-azure.sh \
     --vhd ./bib-output/vpc/disk.vhd \
     --resource-group myRg --storage-account mystore --location eastus \
     --image-name myMicroshiftNvidiaImage
   ```

   The **managed image** is created in the **`--resource-group`** you pass here (the disk lands there too). In the Azure portal (**Virtual machines → Images** or **Custom images**), that same name and resource group are what you use when selecting the image for a new VM. Storage can live in another group via **`--storage-resource-group`**.

   **Next: deploy a VM** — Use the portal or **`az vm create`** (e.g. GPU sizes such as **Standard NC4as T4 v3**, Gen2, same region as the image). The image stays in the **upload** resource group; if the VM lives in another group, select that image by subscription + **image resource group** + name, or pass the full image resource ID to **`az`**. OpenEnv-style **`RESOURCEGROUP`** is not read automatically; map it to **`AZURE_RESOURCE_GROUP`** in **`cloud/azure/.env.azure`** (or pass **`--resource-group`**) for **`push-vhd-to-azure.sh`**. Gen2 **`securityType`** behavior varies by subscription—see [Trusted Launch FAQ](https://aka.ms/TrustedLaunch-FAQ) and current **`az vm create`** documentation if deployment fails on security settings.

**Next:** prerequisites, registry notes, **`argfile.conf`** reference, troubleshooting, and equivalent manual **`podman build`** commands are in **Prerequisites**, **Registries and inputs**, **Build**, and **Disk images (bootc-image-builder) and Azure VHD** below.

**Layout:** the commands above use thin wrappers at the repo root; implementations live in **`build/test-build.sh`**, **`build/build-bootc-disk.sh`**, and **`cloud/azure/`** (**`push-vhd-to-azure.sh`**, **`azure-login-sp.sh`**). Host-only build prep stays under **`scripts/host/`**. Kmod signing input is **`packaging/x509-configuration.ini`**.

---

This branch builds a **fully self-contained** [image mode for RHEL](https://docs.redhat.com/en/documentation/red_hat_build_of_microshift/4.20/html-single/installing_with_image_mode_for_rhel/index) bootc image with:

- **NVIDIA GPU driver** — precompiled, self-signed **`kmod-nvidia`** built in a **local builder image** derived from the **same `BASE_IMAGE`** as the final bootc system ([`Containerfile.builder`](Containerfile.builder)), matching the [fedora-bootc-nvidia](https://github.com/coreos/fedora-bootc-nvidia) split (`BUILDER_IMAGE` + main `Containerfile`). **`scripts/image/dnf-refresh-all.sh`** runs **`dnf upgrade --nobest`** on **all packages including `kernel*`**, then **`kernel-devel`** is aligned to the running **`kernel-core`** before **`rpmbuild`**. The final stage runs the same full refresh so the shipped kernel matches the kmod **when both builds see the same repo metadata** (run **`test-build.sh`** end-to-end; pin **`BASE_IMAGE`** to a digest if a stale kmod/kernel mismatch appears).
- **CUDA user-space** packages from NVIDIA’s public repo and **nvidia-container-toolkit**
- **Self-signed kmod** keys (`packaging/x509-configuration.ini` and the `builder` stage in `Containerfile`)
- **Red Hat build of MicroShift 4.20** — container images **physically embedded** under `/usr/lib/containers/storage` and copied into CRI-O storage before each start via `microshift-copy-images` (Red Hat “physically bound” / disconnected-friendly flow, [Chapter 4](https://docs.redhat.com/en/documentation/red_hat_build_of_microshift/4.20/html-single/installing_with_image_mode_for_rhel/index))
- **NVIDIA Kubernetes Device Plugin** — static manifests under `/etc/microshift/manifests.d/nvidia-device-plugin/` (vendored from [NVIDIA device-plugin static OpenShift deployment](https://gitlab.com/nvidia/kubernetes/device-plugin/-/blob/main/deployments/static/nvidia-device-plugin-privileged-with-service-account.yml)); the **`NVDP_IMAGE`** reference is **embedded** next to the MicroShift release payload so air-gapped nodes do not pull from a registry at runtime
- **CRI-O + NVIDIA Container Toolkit** — `nvidia-ctk runtime configure` for CRI-O (see [NVIDIA GPU on Red Hat Device Edge](https://nvidia.github.io/cloud-native-docs/review/pr-358/edge/latest/nvidia-gpu-with-device-edge.html)), MicroShift drop-in ordering (`10-microshift.conf` / `11-microshift-ovn.conf`), `container_use_devices` SELinux boolean, and the documented `config.toml` runtimes line

The **`main`** branch of the parent **nvidia-bootc** lineage targets the **RHEL AI** / InstructLab-oriented workflow. **This branch** is scoped to **Red Hat build of MicroShift** with **registry.redhat.io** as the primary Red Hat source and **`NVDP_IMAGE`** (default **`nvcr.io`**) embedded for the device plugin. For the public **RHEL AI** reference implementation of bootc + NVIDIA (including **`Containerfile.builder`**, signing, and training layout), see [**RedHatOfficial/rhelai-dev-preview** — `training/nvidia-bootc`](https://github.com/RedHatOfficial/rhelai-dev-preview/tree/main/training/nvidia-bootc).

## Prerequisites

- **Build host**: RHEL 9 with an active subscription so **both** **`Containerfile.builder`** and the **final** `Containerfile` can run `dnf` (BaseOS/AppStream for **`kernel-devel`**, plus **`rhocp-${USHIFT_VER}-…`** and **`fast-datapath-…`** in the final stage). See [MicroShift bootc build prerequisites](https://docs.redhat.com/en/documentation/red_hat_build_of_microshift/4.20/html-single/installing_with_image_mode_for_rhel/index).
- **Tools**: `podman` with support for `--secret` (embedding + `/etc/crio/openshift-pull-secret`), plus network access to `registry.redhat.io`, NVIDIA, and GitHub (NVIDIA packaging sources) during the build.
- **Local user `redhat`**: Created via **`systemd-sysusers`** and **`usr/lib/sysusers.d/10-microshift-nvidia-bootc.conf`** (UID/GID **1000**) so **`bootc container lint`**’s sysusers check passes; password still comes from **`USER_PASSWD`**.
- **Pull secret**: JSON that can pull **`registry.redhat.io`** images: bootc **`BASE_IMAGE`**, OpenShift/MicroShift release images, and any layers referenced while embedding (see `microshift-release-info` / `release-$(uname -m).json` after RPM install). **`NVDP_IMAGE`** is often **`nvcr.io`**; if it needs auth, merge **`nvcr.io`** credentials into the same secret (same file is used for **`--authfile`** and **`--secret id=pullsecret`**).
- **`quay.io/openshift-release-dev`**: `microshift-release-info` often lists payload images on **`quay.io/openshift-release-dev`**. That registry is **not** covered by `podman login registry.redhat.io` alone. Use the **full** pull secret from [console.redhat.com/openshift/downloads](https://console.redhat.com/openshift/downloads#tool-pull-secret) (it includes **`quay.io`**) as **`.pull-secret.json`**, or merge those auths into the file you pass to **`--secret`**. The embed step uses **`scripts/image/embed-microshift-images.sh`**: it runs with **`set -e`**, so the **build fails** if any image cannot be copied (no more silent half-embeds). It also **retries** `quay.io/openshift-release-dev/...` as **`registry.redhat.io/openshift-release-dev/...`** when the first pull fails, which matches common Red Hat mirroring for customer registries.

## Registries and inputs

- **Kmod builder image** (`BUILDER_IMAGE`): tag produced by **`Containerfile.builder`** (e.g. **`localhost/microshift-nvidia-kmod-builder:latest`**). It is **`FROM ${BASE_IMAGE}`** plus toolchain; **`test-build.sh`** builds it before the final image unless **`SKIP_BUILDER=1`**.
- **Base image** (`BASE_IMAGE`): e.g. **`registry.redhat.io/rhel9-eus/rhel-9.6-bootc:9.6`** for **both** the builder layer and the final system. Pin a **digest** so the **same** **`kernel-core`** NVR is used in both builds. Non-EUS alternative: **`registry.redhat.io/rhel9/rhel-bootc:9.6`**.
- **No vendored subscription `.repo` files in the image context**: Red Hat repo access comes from the **build host** RHSM entitlement (and optional `podman build` volume mounts), like the upstream MicroShift image-mode examples—not from static mirror definitions copied into the repository.
- **CUDA + container toolkit**: added at build time from NVIDIA’s public URLs (see `scripts/image/install-microshift-nvidia-stack.sh` and [Device Edge RPM flow](https://nvidia.github.io/cloud-native-docs/review/pr-358/edge/latest/nvidia-gpu-with-device-edge.html)); no vendored `.repo` files are copied into the image ([details](docs/nvidia-repositories.md)).

## `argfile.conf` (main knobs)

There are **no default `ARG` values in `Containerfile` / `Containerfile.builder`** — set everything you need in **`argfile.conf`** (and **`test-build.sh`** loads the same file into the shell for **`BUILDER_IMAGE`**, **`BASE_IMAGE`**, etc.).

| Variable | Role |
| -------- | ---- |
| `BASE_IMAGE` | Bootc base for **`Containerfile.builder`** and the **final** image (**same** `kernel-core` for kmod + runtime). |
| `BUILDER_IMAGE` | Local (or registry) tag for the toolchain image built from **`Containerfile.builder`**. |
| `BASE_URL` | NVIDIA `.run` download base (e.g. Tesla path on `us.download.nvidia.com`). |
| `USER_PASSWD` | **Required** — password for local user `redhat` (MicroShift doc pattern). |
| `DRIVER_VERSION` | NVIDIA driver version (must exist in the enabled NVIDIA module repo). |
| `DRIVER_TYPE` | e.g. `passthrough` (see `Containerfile` / install script). |
| `CUDA_VERSION` | Used to derive `cuda-compat-*` / `cuda-cudart-*` package names. |
| `USHIFT_VER` | MicroShift / repo minor (e.g. `4.20` for `rhocp-4.20-…`). |
| `DISABLE_VGPU_VERSION_CHECK` | Passed through to the image environment. |
| `USE_64K_PAGESIZE` | `1` on aarch64 only: kmod arch `+64k`; **final** stage performs **kernel-64k** rpm-ostree swap when enabled. |
| `IMAGE_VERSION_ID` | Label on the image (`image_version_id`). |
| `RPM_HOST` / `VENDOR` | Passed into the NVIDIA kmod RPM build. |
| `NVDP_IMAGE` | NVIDIA **k8s-device-plugin** image to embed and to run in the DaemonSet (must stay in sync). |
| `CONFIGURE_BUILD_HOST_EUS` | If **`1`**, **`test-build.sh`** runs **`scripts/host/configure-host-rhsm-eus.sh`** (as root via **`sudo`**) before **`podman`** so the **build host** uses EUS BaseOS/AppStream. Set **`0`** on hosts without **`subscription-manager`** (e.g. Fedora) or if you manage RHSM elsewhere. |
| `EUS_RELEASE` | Passed into the image as **`ARG`/`ENV`**. Before every **`dnf upgrade`**, **`scripts/image/dnf-refresh-all.sh`** runs **`scripts/image/rhsm-enable-eus-in-container.sh`** to **`subscription-manager release --set`** and enable **`rhel-9-for-$(uname -m)-{baseos,appstream}-eus-rpms`**, matching [RHEL EUS](https://access.redhat.com/articles/rhel-eus#c5). Containers do **not** automatically see EUS the way the host does ([KB 6712511](https://access.redhat.com/solutions/6712511)); you still need **entitlements** and (typically) the same **`.repo`** definitions as the host. |
| `BUILD_WITH_HOST_RHSM` | Set **`1`** on subscribed RHEL build hosts so **`podman build`** mounts **`/etc/rhsm`** and **`/etc/pki/entitlement`**. When **`EUS_RELEASE`** is set, **`test-build.sh`** also mounts **`/var/lib/rhsm`** and **`/etc/yum.repos.d`** (or turns on **`BUILD_WITH_HOST_YUM_REPOS`** if unset) so **`kernel-devel`** for the bootc kernel resolves from **EUS** instead of default AppStream-only metadata. |
| `CONFIGURE_HOST_NVIDIA_REPOS` | Default **`1`**: before build, run **`scripts/host/configure-host-nvidia-build-repos.sh`** so **CUDA** and **NVIDIA Container Toolkit** **`.repo`** files exist under **`/etc/yum.repos.d`** on the host (required because that directory is often mounted **read-only** into the build). |
| `CONFIGURE_HOST_MICROSHIFT_REPOS` | Default **`1`** when the same host hook runs: **`scripts/host/configure-host-microshift-build-repos.sh`** runs **`subscription-manager repos --enable`** for **`rhocp-${USHIFT_VER}-…`** and **`fast-datapath-…`** so the mounted **`redhat.repo`** already has those repos **enabled** (no **`--enablerepo`** in the **`Containerfile`**). Set **`0`** if you enable those repos yourself or rely on per-transaction **`--enablerepo`** inside the image build. |

## Build

1. Edit **`argfile.conf`**: set **`USER_PASSWD`**, **`BASE_IMAGE`**, **`BUILDER_IMAGE`**, **`DRIVER_VERSION`**, **`CUDA_VERSION`**, **`USHIFT_VER`**, **`NVDP_IMAGE`**, etc.
2. Provide a pull secret: either place **`${REPO}/.pull-secret.json`** (same convention as [bootc-embedded-containers](https://github.com/arthur-r-oliveira/bootc-embedded-containers/tree/rhpds) Quick Start) or use **`podman login registry.redhat.io`** so credentials exist under **`${XDG_RUNTIME_DIR}/containers/auth.json`**.
3. Run:

```bash
chmod +x test-build.sh
./test-build.sh
```

**`test-build.sh`** (default behavior):

1. **Sources `argfile.conf`** into the environment (same keys as **`podman --build-arg-file`**).
2. If **`CONFIGURE_BUILD_HOST_EUS=1`** and **`EUS_RELEASE`** is set, configures the **build host** RHSM: **`subscription-manager release --set`**, disables standard **`rhel-9-for-$(uname -m)-{baseos,appstream}-rpms`**, enables **`…-eus-rpms`** (BaseOS + AppStream EUS), then **`subscription-manager refresh`**, per [Red Hat EUS](https://access.redhat.com/articles/rhel-eus#c5). Requires **sudo** on RHEL; no-ops if **`subscription-manager`** is missing. Your subscription must include **EUS** for those repos.
3. **`podman pull`** **`BASE_IMAGE`** (unless **`SKIP_PRE_PULL=1`**).
4. **`podman build -f Containerfile.builder -t "${BUILDER_IMAGE}"`** (unless **`SKIP_BUILDER=1`** if you already have that tag).
5. **`podman build -f Containerfile`** for the final tag (**`FINAL_IMAGE_TAG`**, default **`microshift-nvidia-bootc-test`**).

**`Containerfile.builder`** runs **`scripts/image/dnf-refresh-all.sh`** (full **`dnf upgrade`**) twice around toolchain installs, with **`ensure_kernel_devel`** so **`kernel-devel`** tracks **`kernel-core`**. The main **`Containerfile`** builder stage runs **`dnf-refresh-all.sh`** again before **`rpmbuild`**, re-deriving kernel macros from the **current** **`kernel-core`**. The **final** stage runs **`dnf-bootstrap-final.sh`**, which calls **`dnf-refresh-all.sh`** before **`install-microshift-nvidia-stack.sh`** does another full refresh.

For **air-gapped** or **digest-pinned** builds, skip the pull: **`SKIP_PRE_PULL=1`** and **`PODMAN_BUILD_PULL=missing ./test-build.sh`**.

On a subscribed workstation, use **`BUILD_WITH_HOST_RHSM=1`** (default in **`argfile.conf`** when using **`rhel9-eus`**). With **`EUS_RELEASE`** set, **`test-build.sh`** mounts **`/var/lib/rhsm`** and **`/etc/yum.repos.d`** into the build so **`dnf`** inside the container uses the same **EUS** **`redhat.repo`** and RHSM state as the host—addressing the “**No match for kernel-devel-…**” / **404 on EUS metadata** class of failures described in [How to install RHEL EUS packages on UBI](https://access.redhat.com/solutions/6712511). **`CONFIGURE_BUILD_HOST_EUS=1`** should run **first** on the host so **`redhat.repo`** lists the **`-eus-rpms`** repos.

`test-build.sh` resolves an **`AUTHFILE`** (`.pull-secret.json` in the repo directory first, then podman’s `auth.json`) and passes the **same path** to **`--authfile`** and **`--secret id=pullsecret,src=…`**. That matches the embed pattern used in **`bootc-embedded-containers`** [`Containerfile.4.20`](https://github.com/arthur-r-oliveira/bootc-embedded-containers/blob/rhpds/Containerfile.4.20) (`RUN --mount=type=secret,id=pullsecret,dst=/run/secrets/pull-secret.json` + `skopeo … --authfile /run/secrets/pull-secret.json`). The upstream [**`build.sh`**](https://github.com/arthur-r-oliveira/bootc-embedded-containers/blob/rhpds/build.sh) bind-mounts **`/etc/rhsm`**, **`/etc/pki/entitlement`**, and optionally **`/etc/yum.repos.d`** into **`podman build`** so Red Hat repos work without copying certificates into the context. This repo does the same when you set **`BUILD_WITH_HOST_RHSM=1`** (add **`BUILD_WITH_HOST_YUM_REPOS=1`** to mount **`/etc/yum.repos.d`** read-only). Otherwise, rely on your builder environment’s subscription and secret injection (CI/CD or self-hosted runner).

**Curl error (58) / PEM “Permission denied” on `cdn.redhat.com` during `dnf`:** On **SELinux** hosts, bind-mounted **`/etc/pki/entitlement`** keys are often unreadable inside the build unless relabeled. **`test-build.sh`** defaults to **`--volume …:ro,z`** (and **`rw,z`** for entitlements when **`BUILD_ENTITLEMENT_VOLUME_RW=1`**) so Podman applies a shared MCS label. To avoid relabeling host files, set **`BUILD_RHSM_VOLUME_SELINUX_LABEL=none`** (you may need **`sudo podman build`** or **`--security-opt label=disable`** on the build instead—only if you understand the tradeoff). **`restorecon -RFv /etc/pki/entitlement`** on the host is another recovery step if labels were altered.

**`[Errno 30] Read-only file system` on `/etc/yum.repos.d/cuda-rhel9.repo`:** EUS builds mount **`/etc/yum.repos.d`** read-only so the **`Containerfile`** cannot write **`cuda-rhel9.repo`** there (no **`curl -o`** / host drop-in). **`test-build.sh`** runs **`scripts/host/configure-host-nvidia-build-repos.sh`** (as **root**) before **`podman build`** when **`BUILD_WITH_HOST_RHSM=1`** and **`yum.repos.d`** will be mounted—creating **`cuda-rhel9.repo`** and **`nvidia-container-toolkit.repo`** on the host. **`scripts/image/install-microshift-nvidia-stack.sh`** (installed as **`/usr/bin/install-microshift-nvidia-stack.sh`**) then reuses those files. Set **`CONFIGURE_HOST_NVIDIA_REPOS=0`** to skip the host hook and install the `.repo` files yourself.

**Equivalent manual commands** (after setting variables from **`argfile.conf`** or exporting them):

```bash
AUTHFILE="${PWD}/.pull-secret.json"   # or ${XDG_RUNTIME_DIR}/containers/auth.json
set -a
# shellcheck disable=SC1091
source argfile.conf
set +a

podman pull --authfile "${AUTHFILE}" "${BASE_IMAGE}"
podman build --authfile "${AUTHFILE}" --build-arg-file argfile.conf \
  -f Containerfile.builder -t "${BUILDER_IMAGE}" .

podman build --authfile "${AUTHFILE}" --secret id=pullsecret,src="${AUTHFILE}" \
  --build-arg-file argfile.conf \
  -f Containerfile -t microshift-nvidia-bootc:latest .
```

### Disk images (bootc-image-builder) and Azure VHD

1. Build a **VHD** with [bootc-image-builder](https://osbuild.org/docs/bootc/#-image-types) (privileged **`podman`**, **`osbuild-selinux`** on SELinux hosts):

   ```bash
   chmod +x build-bootc-disk.sh
   sudo ./build-bootc-disk.sh -t vhd -o ./bib-output localhost/YOUR_BOOTC_TAG:latest
   ```

   Artifacts land under **`bib-output/`** (gitignored). The VHD path depends on bib/osbuild (e.g. **`bib-output/vpc/disk.vhd`** or **`bib-output/vhd/disk.vhd`**); use **`find bib-output -name '*.vhd'`** if unsure.

   **Same image as `podman build`:** `build-bootc-disk.sh` bind-mounts **`/var/lib/containers/storage`** into BIB. Use **rootful** Podman for both **`podman build`** and **`sudo ./build-bootc-disk.sh`**. A **rootless** `podman build` updates a **different** store than **`sudo podman inspect`** / BIB see—`localhost/...:latest` can point at an old digest for disk builds while `podman run` as your user shows another. Prefer **`sudo podman build …`** (or `podman save | sudo podman load`) so **one** `latest` is canonical.

   **Pin what you bake:** Before BIB, record **`sudo podman inspect localhost/YOUR_BOOTC_TAG:latest --format '{{.Digest}}'`**. Optionally pass **`localhost/YOUR_BOOTC_TAG@sha256:…`** to **`build-bootc-disk.sh`** so a floating **`latest`** cannot pick stale layers. After BIB, record **`sha256sum bib-output/vpc/disk.vhd`** (or your path) and keep it next to the digest so you can prove which VM used which artifact.

   **VM boots old content:** If **`sudo bootc status`** on the node shows a **digest** that does not match the image you built, the **VHD / managed image in Azure** came from an older disk or upload—not a silent loss of **`kmod-nvidia`** in the OCI image. Confirm with **`sudo podman run --rm YOUR_IMAGE rpm -qa 'kmod-nvidia-*'`** on the build host first.

2. Upload the VHD to Azure and create a **managed disk** / **managed image** with the Azure CLI, following the same pattern as Red Hat’s guide for custom RHEL on Azure ([*Deploying RHEL 9 on Microsoft Azure*](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/deploying_rhel_9_on_microsoft_azure/index)):

   ```bash
   chmod +x push-vhd-to-azure.sh
   ./push-vhd-to-azure.sh --dry-run \
     --vhd ./bib-output/vpc/disk.vhd \
     --resource-group myRg --storage-account mystore --location eastus \
     --image-name myMicroshiftNvidiaImage
   az login   # if needed
   ./push-vhd-to-azure.sh \
     --vhd ./bib-output/vpc/disk.vhd \
     --resource-group myRg --storage-account mystore --location eastus \
     --image-name myMicroshiftNvidiaImage
   ```

   Use **`--upload-only`** if you only need the page blob. For VM sizing, drivers, and fixed-VHD details, use the Azure chapters in that document (e.g. uploading and creating an image, VM settings).

### CI / pipelines

If you build through a pipeline, expose registry credentials as a build secret mounted where the **`Containerfile`** expects **`--secret id=pullsecret,src=…`** (or equivalent). Ensure the secret name in your pipeline matches what the build task passes to **`podman`**.

Pipelines that only run **`podman build -f Containerfile`** must be extended to **build `Containerfile.builder` first** and tag **`BUILDER_IMAGE`** (or push/pull that image as a cache), matching **`argfile.conf`**, so the kmod stage is not skipped.

## After deployment

- Log in as user **`redhat`** (password from `USER_PASSWD`) or your cloud **SSH user** (image may also allow **`azureuser`** depending on how the disk was produced).
- Confirm the **booted bootc image** matches what you built: **`sudo bootc status`** — compare **Digest** to **`sudo podman inspect … --format '{{.Digest}}'`** on the build host for the same tag.
- Check MicroShift: **`sudo oc get pods -A --kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig`** (see the [installing with image mode](https://docs.redhat.com/en/documentation/red_hat_build_of_microshift/4.20/html-single/installing_with_image_mode_for_rhel/index) verification steps).
- **Greenboot**: **`sudo systemctl status greenboot-healthcheck.service`** should show **SUCCESS** once core MicroShift workloads are ready (e.g. **`40_microshift_running_check.sh`**).

### Validated smoke test (GPU + MicroShift + CUDA)

The following was exercised on an **Azure NC-series** VM (e.g. **Tesla T4**) booted from a VHD built from this image; use it as a reference checklist.

**Host driver**

- **`sudo nvidia-smi -L`** lists the GPU.
- **`lsmod | grep nvidia`** shows **`nvidia`**, **`nvidia_uvm`**, **`nvidia_modeset`**, **`nvidia_drm`** loaded.
- **`dmesg | grep -i nvidia`** may report **`module verification failed: signature and/or required key missing - tainting kernel`** for the **self-signed OOT kmod**—expected when Secure Boot is off and the module is not in the firmware trust DB; the driver still loads. You may also see **`[drm] No compatible format found`** / **`Cannot find any crtc or sizes`** on a **headless / compute** GPU; that is normal without a display stack.

**Kubernetes**

- **`sudo oc get pods -A --kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig`** — expect **`nvidia-device-plugin`** DaemonSet **Running**.
- **`sudo oc describe node "$(hostname -s)" --kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig`** — **Capacity** and **Allocatable** should include **`nvidia.com/gpu: 1`** (for a single-GPU VM).

**CUDA workload (optional)**

Create a namespace and a one-shot pod that requests a GPU, for example **`nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubi8`** with **`resources.limits.nvidia.com/gpu: 1`**. After **`Completed`**, **`sudo oc logs -n <ns> <pod> --kubeconfig …`** should end with **`Test PASSED`**.

### GPU VM (e.g. Azure N-series) — driver not loading / `nvidia-smi` missing

The **kernel module** must load before **NVML** (`nvidia-smi`, `nvidia-ctk cdi generate`). This image uses an **OOT kmod** signed with the build-time key in **`packaging/x509-configuration.ini`**.

1. **VM SKU**: Use a **GPU** size (e.g. Azure **NC**/ **ND**/ **NV**). On a CPU-only VM, `modprobe nvidia` will not create devices.
2. **Order of boot**: **`nvidia-toolkit-firstboot`** is wired for **`multi-user.target`** with **`modprobe`** pre-commands and **`/etc/modules-load.d/nvidia.conf`** so modules are not expected to load during **`basic.target`** anymore.
3. **Secure Boot** (common on Azure Gen2): If the kmod is **refused by the kernel**, enroll **MOK** with the public key used at RPM build time, or **disable Secure Boot** for a lab VM. Check: `sudo modprobe -v nvidia` and `journalctl -b -p err | grep -i nvidia`.
4. **Kernel match**: If `modprobe` reports **invalid module format**, rebuild the image so **`kmod-nvidia`** matches **`kernel-core`** (see **Kernel alignment** below).
5. **`nvidia-smi`**: Provided by **`nvidia-driver-cuda`**; path is normally **`/usr/bin/nvidia-smi`**. If the module never loaded, installs can look “broken” until step 3–4 are fixed.

## Kernel alignment (peer review)

The **`kmod-nvidia` RPM** must match **`kernel-core` on the node**. With **full `dnf upgrade` (including kernel)** in both the builder path and the final image, the **resolved kernel NVR** should match **if `Containerfile.builder` and the final `Containerfile` run back-to-back** against the same entitlements/repos. If a **new kernel** lands in repos **between** the two builds, the install script’s **kmod vs `kernel-core` check** fails—re-run **`./test-build.sh`** without **`SKIP_BUILDER=1`**, or pin **`BASE_IMAGE`** to a digest and rebuild both stages.

When debugging:

```bash
podman run --rm "${BUILDER_IMAGE}" rpm -q kernel-core
podman run --rm localhost/microshift-nvidia-bootc-test rpm -q kernel-core   # or your final tag
```

The install script **versionlocks** kernel packages before **MicroShift** installs, **fails** if **`kmod-nvidia`** does not match **`kernel-core`**, and **`scripts/image/verify-nvidia-kmod.sh`** checks **`nvidia.ko`**.

**NVIDIA `580` vs RHEL kernel `570`:** `DRIVER_VERSION=580.x` is the **NVIDIA driver** branch. **`5.14.0-570.xx.y`** in **`kernel-core`** is the **Red Hat kernel** NVR — not “NVIDIA 570.”

**After deploy:** Prefer a **single bootc digest** and controlled **`bootc upgrade`** so the node does not move to a **new kernel** without a **new image** with a matching **`kmod-nvidia`**.

## Notes

- **Lineage:** The **kmod builder + final image** split and precompiled NVIDIA kmod approach follow patterns publicized for **RHEL AI** in [**rhelai-dev-preview/training/nvidia-bootc**](https://github.com/RedHatOfficial/rhelai-dev-preview/tree/main/training/nvidia-bootc) and the [fedora-bootc-nvidia](https://github.com/coreos/fedora-bootc-nvidia) reference; this branch adds **MicroShift** embedding, CRI-O/toolkit wiring, and EUS-aware host build hooks.
- This branch uses a **fedora-bootc-nvidia–style** **`Containerfile.builder`** instead of **`registry.redhat.io/openshift4/driver-toolkit-rhel9`**, so **EUS bootc** kernels are not skewed against an OpenShift Driver Toolkit kernel built for a different stream.
- **Embedded images**: do not point **`/etc/containers/storage.conf`** `additionalimagestores` at `/usr/lib/containers/storage` for this pattern; Red Hat documents that bootc updates can break in that configuration when images are embedded this way.
