# NVIDIA + MicroShift bootc image (RHEL 9.6)

**Branch: `feature/rhel96-microshift-nvidia-bootc`**

This branch builds a **fully self-contained** [image mode for RHEL](https://docs.redhat.com/en/documentation/red_hat_build_of_microshift/4.20/html-single/installing_with_image_mode_for_rhel/index) bootc image with:

- **NVIDIA GPU driver** — precompiled, self-signed **`kmod-nvidia`** built in a **local builder image** derived from the **same `BASE_IMAGE`** as the final bootc system ([`Containerfile.builder`](Containerfile.builder)), matching the [fedora-bootc-nvidia](https://github.com/coreos/fedora-bootc-nvidia) split (`BUILDER_IMAGE` + main `Containerfile`). **`scripts/dnf-refresh-all.sh`** runs **`dnf upgrade --nobest`** on **all packages including `kernel*`**, then **`kernel-devel`** is aligned to the running **`kernel-core`** before **`rpmbuild`**. The final stage runs the same full refresh so the shipped kernel matches the kmod **when both builds see the same repo metadata** (run **`test-build.sh`** end-to-end; pin **`BASE_IMAGE`** to a digest if a stale kmod/kernel mismatch appears).
- **CUDA user-space** packages from NVIDIA’s public repo and **nvidia-container-toolkit**
- **Self-signed kmod** keys (`x509-configuration.ini` and the `builder` stage in `Containerfile`)
- **Red Hat build of MicroShift 4.20** — container images **physically embedded** under `/usr/lib/containers/storage` and copied into CRI-O storage before each start via `microshift-copy-images` (Red Hat “physically bound” / disconnected-friendly flow, [Chapter 4](https://docs.redhat.com/en/documentation/red_hat_build_of_microshift/4.20/html-single/installing_with_image_mode_for_rhel/index))
- **NVIDIA Kubernetes Device Plugin** — static manifests under `/etc/microshift/manifests.d/nvidia-device-plugin/` (vendored from [NVIDIA device-plugin static OpenShift deployment](https://gitlab.com/nvidia/kubernetes/device-plugin/-/blob/main/deployments/static/nvidia-device-plugin-privileged-with-service-account.yml)); the **`NVDP_IMAGE`** reference is **embedded** next to the MicroShift release payload so air-gapped nodes do not pull from a registry at runtime
- **CRI-O + NVIDIA Container Toolkit** — `nvidia-ctk runtime configure` for CRI-O (see [NVIDIA GPU on Red Hat Device Edge](https://nvidia.github.io/cloud-native-docs/review/pr-358/edge/latest/nvidia-gpu-with-device-edge.html)), MicroShift drop-in ordering (`10-microshift.conf` / `11-microshift-ovn.conf`), `container_use_devices` SELinux boolean, and the documented `config.toml` runtimes line

This repository builds **MicroShift** on image-mode RHEL with **registry.redhat.io** as the primary Red Hat image source; **`NVDP_IMAGE`** (default **`nvcr.io`**) for the NVIDIA Kubernetes Device Plugin is **embedded** with the release payload so nodes can run without pulling that image at runtime.

## Prerequisites

- **Build host**: RHEL 9 with an active subscription so **both** **`Containerfile.builder`** and the **final** `Containerfile` can run `dnf` (BaseOS/AppStream for **`kernel-devel`**, plus **`rhocp-${USHIFT_VER}-…`** and **`fast-datapath-…`** in the final stage). See [MicroShift bootc build prerequisites](https://docs.redhat.com/en/documentation/red_hat_build_of_microshift/4.20/html-single/installing_with_image_mode_for_rhel/index).
- **Tools**: `podman` with support for `--secret` (embedding + `/etc/crio/openshift-pull-secret`), plus network access to `registry.redhat.io`, NVIDIA, and GitHub (NVIDIA packaging sources) during the build.
- **Local user `redhat`**: Created via **`systemd-sysusers`** and **`usr/lib/sysusers.d/10-microshift-nvidia-bootc.conf`** (UID/GID **1000**) so **`bootc container lint`**’s sysusers check passes; password still comes from **`USER_PASSWD`**.
- **Pull secret**: JSON that can pull **`registry.redhat.io`** images: bootc **`BASE_IMAGE`**, OpenShift/MicroShift release images, and any layers referenced while embedding (see `microshift-release-info` / `release-$(uname -m).json` after RPM install). **`NVDP_IMAGE`** is often **`nvcr.io`**; if it needs auth, merge **`nvcr.io`** credentials into the same secret (same file is used for **`--authfile`** and **`--secret id=pullsecret`**).
- **`quay.io/openshift-release-dev`**: `microshift-release-info` often lists payload images on **`quay.io/openshift-release-dev`**. That registry is **not** covered by `podman login registry.redhat.io` alone. Use the **full** pull secret from [console.redhat.com/openshift/downloads](https://console.redhat.com/openshift/downloads#tool-pull-secret) (it includes **`quay.io`**) as **`.pull-secret.json`**, or merge those auths into the file you pass to **`--secret`**. The embed step uses **`scripts/embed-microshift-images.sh`**: it runs with **`set -e`**, so the **build fails** if any image cannot be copied (no more silent half-embeds). It also **retries** `quay.io/openshift-release-dev/...` as **`registry.redhat.io/openshift-release-dev/...`** when the first pull fails, which matches common Red Hat mirroring for customer registries.

## Registries and inputs

- **Kmod builder image** (`BUILDER_IMAGE`): tag produced by **`Containerfile.builder`** (e.g. **`localhost/microshift-nvidia-kmod-builder:latest`**). It is **`FROM ${BASE_IMAGE}`** plus toolchain; **`test-build.sh`** builds it before the final image unless **`SKIP_BUILDER=1`**.
- **Base image** (`BASE_IMAGE`): e.g. **`registry.redhat.io/rhel9-eus/rhel-9.6-bootc:9.6`** for **both** the builder layer and the final system. Pin a **digest** so the **same** **`kernel-core`** NVR is used in both builds. Non-EUS alternative: **`registry.redhat.io/rhel9/rhel-bootc:9.6`**.
- **No baked-in private repo definitions**: the `Containerfile` does not ship internal RHSM or `.repo` drop-ins; repository access comes from the **build host** subscription, like the usual MicroShift bootc pattern.
- **CUDA + container toolkit**: added at build time from NVIDIA’s public URLs (see `scripts/install-microshift-nvidia-stack.sh` and [Device Edge RPM flow](https://nvidia.github.io/cloud-native-docs/review/pr-358/edge/latest/nvidia-gpu-with-device-edge.html)); nothing under `repos/` is copied into the image.

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
| `CONFIGURE_BUILD_HOST_EUS` | If **`1`**, **`test-build.sh`** runs **`scripts/configure-host-rhsm-eus.sh`** (as root via **`sudo`**) before **`podman`** so the **build host** uses EUS BaseOS/AppStream. Set **`0`** on hosts without **`subscription-manager`** (e.g. Fedora) or if you manage RHSM elsewhere. |
| `EUS_RELEASE` | Passed into the image as **`ARG`/`ENV`**. Before every **`dnf upgrade`**, **`scripts/dnf-refresh-all.sh`** runs **`scripts/rhsm-enable-eus-in-container.sh`** to **`subscription-manager release --set`** and enable **`rhel-9-for-$(uname -m)-{baseos,appstream}-eus-rpms`**, matching [RHEL EUS](https://access.redhat.com/articles/rhel-eus#c5). Containers do **not** automatically see EUS the way the host does ([KB 6712511](https://access.redhat.com/solutions/6712511)); you still need **entitlements** and (typically) the same **`.repo`** definitions as the host. |
| `BUILD_WITH_HOST_RHSM` | Set **`1`** on subscribed RHEL build hosts so **`podman build`** mounts **`/etc/rhsm`** and **`/etc/pki/entitlement`**. When **`EUS_RELEASE`** is set, **`test-build.sh`** also mounts **`/var/lib/rhsm`** and **`/etc/yum.repos.d`** (or turns on **`BUILD_WITH_HOST_YUM_REPOS`** if unset) so **`kernel-devel`** for the bootc kernel resolves from **EUS** instead of default AppStream-only metadata. |
| `CONFIGURE_HOST_NVIDIA_REPOS` | Default **`1`**: before build, run **`scripts/configure-host-nvidia-build-repos.sh`** so **CUDA** and **NVIDIA Container Toolkit** **`.repo`** files exist under **`/etc/yum.repos.d`** on the host (required because that directory is often mounted **read-only** into the build). |
| `CONFIGURE_HOST_MICROSHIFT_REPOS` | Default **`1`** when the same host hook runs: **`scripts/configure-host-microshift-build-repos.sh`** runs **`subscription-manager repos --enable`** for **`rhocp-${USHIFT_VER}-…`** and **`fast-datapath-…`** so the mounted **`redhat.repo`** already has those repos **enabled** (no **`--enablerepo`** in the **`Containerfile`**). Set **`0`** if you enable those repos yourself or rely on per-transaction **`--enablerepo`** inside the image build. |

## Build

1. Edit **`argfile.conf`**: set **`USER_PASSWD`**, **`BASE_IMAGE`**, **`BUILDER_IMAGE`**, **`DRIVER_VERSION`**, **`CUDA_VERSION`**, **`USHIFT_VER`**, **`NVDP_IMAGE`**, etc.
2. Provide a pull secret: either place **`${REPO}/.pull-secret.json`** (same convention as [bootc-embedded-containers](https://github.com/arthur-r-oliveira/bootc-embedded-containers) Quick Start) or use **`podman login registry.redhat.io`** so credentials exist under **`${XDG_RUNTIME_DIR}/containers/auth.json`**.
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

**`Containerfile.builder`** runs **`scripts/dnf-refresh-all.sh`** (full **`dnf upgrade`**) twice around toolchain installs, with **`ensure_kernel_devel`** so **`kernel-devel`** tracks **`kernel-core`**. The main **`Containerfile`** builder stage runs **`dnf-refresh-all.sh`** again before **`rpmbuild`**, re-deriving kernel macros from the **current** **`kernel-core`**. The **final** stage runs **`dnf-bootstrap-final.sh`**, which calls **`dnf-refresh-all.sh`** before **`install-microshift-nvidia-stack.sh`** does another full refresh.

For **air-gapped** or **digest-pinned** builds, skip the pull: **`SKIP_PRE_PULL=1`** and **`PODMAN_BUILD_PULL=missing ./test-build.sh`**.

On a subscribed workstation, use **`BUILD_WITH_HOST_RHSM=1`** (default in **`argfile.conf`** when using **`rhel9-eus`**). With **`EUS_RELEASE`** set, **`test-build.sh`** mounts **`/var/lib/rhsm`** and **`/etc/yum.repos.d`** into the build so **`dnf`** inside the container uses the same **EUS** **`redhat.repo`** and RHSM state as the host—addressing the “**No match for kernel-devel-…**” / **404 on EUS metadata** class of failures described in [How to install RHEL EUS packages on UBI](https://access.redhat.com/solutions/6712511). **`CONFIGURE_BUILD_HOST_EUS=1`** should run **first** on the host so **`redhat.repo`** lists the **`-eus-rpms`** repos.

`test-build.sh` resolves an **`AUTHFILE`** (`.pull-secret.json` in the repo directory first, then podman’s `auth.json`) and passes the **same path** to **`--authfile`** and **`--secret id=pullsecret,src=…`**. That matches the embed pattern used in [**bootc-embedded-containers**](https://github.com/arthur-r-oliveira/bootc-embedded-containers) (e.g. `RUN --mount=type=secret,id=pullsecret,dst=/run/secrets/pull-secret.json` + `skopeo … --authfile /run/secrets/pull-secret.json`). The companion **`build.sh`** there bind-mounts **`/etc/rhsm`**, **`/etc/pki/entitlement`**, and optionally **`/etc/yum.repos.d`** into **`podman build`** so Red Hat repos work without copying certificates into the context. This repo does the same when you set **`BUILD_WITH_HOST_RHSM=1`** (add **`BUILD_WITH_HOST_YUM_REPOS=1`** to mount **`/etc/yum.repos.d`** read-only). Otherwise, rely on the **build host**’s Red Hat subscription or equivalent repo access inside the build.

**Curl error (58) / PEM “Permission denied” on `cdn.redhat.com` during `dnf`:** On **SELinux** hosts, bind-mounted **`/etc/pki/entitlement`** keys are often unreadable inside the build unless relabeled. **`test-build.sh`** defaults to **`--volume …:ro,z`** (and **`rw,z`** for entitlements when **`BUILD_ENTITLEMENT_VOLUME_RW=1`**) so Podman applies a shared MCS label. To avoid relabeling host files, set **`BUILD_RHSM_VOLUME_SELINUX_LABEL=none`** (you may need **`sudo podman build`** or **`--security-opt label=disable`** on the build instead—only if you understand the tradeoff). **`restorecon -RFv /etc/pki/entitlement`** on the host is another recovery step if labels were altered.

**`[Errno 30] Read-only file system` on `/etc/yum.repos.d/cuda-rhel9.repo`:** EUS builds mount **`/etc/yum.repos.d`** read-only so the **`Containerfile`** cannot write **`cuda-rhel9.repo`** there (no **`curl -o`** / host drop-in). **`test-build.sh`** runs **`scripts/configure-host-nvidia-build-repos.sh`** (as **root**) before **`podman build`** when **`BUILD_WITH_HOST_RHSM=1`** and **`yum.repos.d`** will be mounted—creating **`cuda-rhel9.repo`** and **`nvidia-container-toolkit.repo`** on the host. **`install-microshift-nvidia-stack.sh`** then reuses those files. Set **`CONFIGURE_HOST_NVIDIA_REPOS=0`** to skip the host hook and install the `.repo` files yourself.

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

## After deployment

- Log in as user **`redhat`** (password from `USER_PASSWD`).
- Check MicroShift: `sudo oc get pods -A --kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig` (see the [installing with image mode](https://docs.redhat.com/en/documentation/red_hat_build_of_microshift/4.20/html-single/installing_with_image_mode_for_rhel/index) verification steps).
- On a GPU node, confirm the device plugin: `oc get pods -n nvidia-device-plugin` and `oc describe node` shows **`nvidia.com/gpu`** capacity after the driver is loaded.

### GPU VM (e.g. Azure N-series) — driver not loading / `nvidia-smi` missing

The **kernel module** must load before **NVML** (`nvidia-smi`, `nvidia-ctk cdi generate`). This image uses an **OOT kmod** signed with the build-time key in **`x509-configuration.ini`**.

1. **VM SKU**: Use a **GPU** size (e.g. Azure **NC**/ **ND**/ **NV**). On a CPU-only VM, `modprobe nvidia` will not create devices.
2. **Order of boot**: **`nvidia-toolkit-firstboot`** is wired for **`multi-user.target`** with **`modprobe`** pre-commands and **`/etc/modules-load.d/nvidia.conf`** so modules are not expected to load during **`basic.target`** anymore.
3. **Secure Boot** (common on Azure Gen2): If the kmod is **refused by the kernel**, enroll **MOK** with the public key used at RPM build time, or **disable Secure Boot** for a lab VM. Check: `sudo modprobe -v nvidia` and `journalctl -b -p err | grep -i nvidia`.
4. **Kernel match**: If `modprobe` reports **invalid module format**, rebuild the image so **`kmod-nvidia`** matches **`kernel-core`** (see **Kernel alignment** below).
5. **`nvidia-smi`**: Provided by **`nvidia-driver-cuda`**; path is normally **`/usr/bin/nvidia-smi`**. If the module never loaded, installs can look “broken” until step 3–4 are fixed.

## Kernel alignment

The **`kmod-nvidia` RPM** must match **`kernel-core` on the node**. With **full `dnf upgrade` (including kernel)** in both the builder path and the final image, the **resolved kernel NVR** should match **if `Containerfile.builder` and the final `Containerfile` run back-to-back** against the same entitlements/repos. If a **new kernel** lands in repos **between** the two builds, the install script’s **kmod vs `kernel-core` check** fails—re-run **`./test-build.sh`** without **`SKIP_BUILDER=1`**, or pin **`BASE_IMAGE`** to a digest and rebuild both stages.

When debugging:

```bash
podman run --rm "${BUILDER_IMAGE}" rpm -q kernel-core
podman run --rm localhost/microshift-nvidia-bootc-test rpm -q kernel-core   # or your final tag
```

The install script **versionlocks** kernel packages before **MicroShift** installs, **fails** if **`kmod-nvidia`** does not match **`kernel-core`**, and **`verify-nvidia-kmod.sh`** checks **`nvidia.ko`**.

**NVIDIA `580` vs RHEL kernel `570`:** `DRIVER_VERSION=580.x` is the **NVIDIA driver** branch. **`5.14.0-570.xx.y`** in **`kernel-core`** is the **Red Hat kernel** NVR — not “NVIDIA 570.”

**After deploy:** Prefer a **single bootc digest** and controlled **`bootc upgrade`** so the node does not move to a **new kernel** without a **new image** with a matching **`kmod-nvidia`**.

## Notes

- This branch uses a **fedora-bootc-nvidia–style** **`Containerfile.builder`** instead of **`registry.redhat.io/openshift4/driver-toolkit-rhel9`**, so **EUS bootc** kernels are not skewed against an OpenShift DTK kernel.
- **Embedded images**: do not point **`/etc/containers/storage.conf`** `additionalimagestores` at `/usr/lib/containers/storage` for this pattern; Red Hat documents that bootc updates can break in that configuration when images are embedded this way.
