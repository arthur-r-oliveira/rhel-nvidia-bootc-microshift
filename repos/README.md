# Repository stubs

CUDA and NVIDIA Container Toolkit `.repo` files are **not** vendored here. The image build adds them at install time:

- **CUDA**: `dnf config-manager --add-repo=https://developer.download.nvidia.com/compute/cuda/repos/rhel9/<arch>/cuda-rhel9.repo` (x86_64 uses `x86_64`; aarch64 uses `sbsa`), per [NVIDIA GPU on Red Hat Device Edge](https://nvidia.github.io/cloud-native-docs/review/pr-358/edge/latest/nvidia-gpu-with-device-edge.html).
- **Container toolkit**: `curl …/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo`.

GPG keys ship with those upstream repo definitions; do not `COPY` Red Hat entitlement certificates into the image—use host `podman build --volume` for `/etc/rhsm` and `/etc/pki/entitlement` when needed (see root `README.md`).
