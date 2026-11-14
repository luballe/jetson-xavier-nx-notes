# Software stack

What was installed on top of Jetson Linux 35.6.5, how, and how each piece was verified.

## Versions

| Component | Version | Source |
|---|---|---|
| CUDA | 11.4 (`nvcc` 11.4.315) | NVIDIA apt repo |
| cuDNN | 8.6.0 | NVIDIA apt repo |
| TensorRT | 8.5.2 | NVIDIA apt repo |
| VPI | 2.4.8 | NVIDIA apt repo |
| PyTorch | 2.1.0a0+41361538.nv23.06 | NVIDIA wheel for JetPack 5, Python 3.8 |
| torchvision | 0.16.1 | Built from source |
| OpenCV | 4.10.0 with contrib | Built from source |
| NumPy | 1.24.4 | pip (the last line that supports Python 3.8) |
| onnx | 1.17.0 | pip |
| OpenBLAS | 0.3.28, OpenMP | Built from source and used as the system BLAS and LAPACK; the 0.3.8 from apt gives NaN, see the PyTorch section |

## JetPack components from apt

The apt sources for `repo.download.nvidia.com/jetson` are already configured on a flashed system.

```bash
sudo apt install nvidia-cuda nvidia-cudnn8 nvidia-tensorrt nvidia-opencv
```

Those metapackages install **runtime libraries only**. There is no `nvcc`, no headers and no Python bindings for TensorRT until you add the `-dev` ones:

```bash
sudo apt install nvidia-cuda-dev nvidia-cudnn8-dev nvidia-tensorrt-dev
```

`nvidia-opencv-dev` fails with "held broken packages" because NVIDIA's `libopencv-dev` conflicts with Ubuntu's OpenCV 4.2 header packages that ship in the sample root filesystem. Naming the package explicitly lets apt replace them:

```bash
sudo apt install libopencv-dev=4.5.4-8-g3e4c170df4 nvidia-opencv-dev
```

(Not needed if you are going to build OpenCV yourself, as below.)

Add CUDA to the shell:

```bash
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
```

### VPI

```bash
sudo apt install libnvvpi2 python3.8-vpi2 vpi2-dev vpi2-samples
```

Installing these directly instead of the `nvidia-vpi` metapackage avoids pulling in a second Python (3.9).

A 5x5 box filter ran on all three backends. CPU and CUDA agreed; the PVA result differed by about 2 % in mean value. The cause was not investigated, so compare outputs before relying on PVA for anything numeric.

## PyTorch

NVIDIA publishes wheels for JetPack 5 only for Python 3.8. Standard `pip install torch` gives a CPU-only build.

```bash
sudo apt install python3-pip libopenblas-dev libopenmpi-dev libomp-dev
sudo -H python3 -m pip install --upgrade pip
sudo -H python3 -m pip install "numpy==1.24.4"
W=torch-2.1.0a0+41361538.nv23.06-cp38-cp38-linux_aarch64.whl
wget https://developer.download.nvidia.com/compute/redist/jp/v512/pytorch/$W
sudo -H python3 -m pip install ./$W
```

Verified with a matrix product and a cuDNN convolution on the GPU. See [scripts/jetson/install_pytorch.sh](../scripts/jetson/install_pytorch.sh).

### Replace OpenBLAS, or CPU results can be NaN

Ubuntu 20.04 ships OpenBLAS 0.3.8, and NVIDIA's PyTorch loads it at run time. That version does not recognise the Carmel CPU and falls back to generic routines that return NaN from matrix products. GPU results are not affected, and neither is NumPy from pip, which bundles its own OpenBLAS.

```python
import torch
a = torch.rand(1024, 1024)
print(torch.isnan(a @ a).any())     # tensor(True) on the first call
```

Fix used here: build OpenBLAS 0.3.28 into `/opt/OpenBLAS` and point every system BLAS/LAPACK alternative at it (`libopenblas.so.0`, `libblas.so.3`, `liblapack.so.3` and the three build-time ones):

```bash
sudo ./scripts/jetson/build_openblas.sh       # about 15 minutes
```

Workaround with no build: `export OPENBLAS_CORETYPE=CORTEXA57`.

The whole story, with the diagnosis, the commands and how OpenCV is (not) affected, is in [07-pytorch-openblas-nan.md](07-pytorch-openblas-nan.md). The test suite checks it (`numpy_system_blas_lapack_direct`, `torch_cpu_blas_first_call`, `torchvision_resnet18_gpu_matches_cpu`, `opencv_linear_algebra_matches_numpy`).

## torchvision

There is no prebuilt wheel matching the NVIDIA PyTorch build. Version 0.16.x pairs with PyTorch 2.1.

```bash
sudo apt install libjpeg-dev zlib1g-dev libpng-dev libpython3-dev
sudo -H python3 -m pip install "pillow<11" requests
git clone --depth 1 --branch v0.16.1 https://github.com/pytorch/vision
cd vision
export BUILD_VERSION=0.16.1
sudo -E python3 setup.py install
```

The build compiles one file at a time and took 45 minutes. See [scripts/jetson/build_torchvision.sh](../scripts/jetson/build_torchvision.sh).

For video work also install the GStreamer parsers (`h264parse`, `h265parse`), which the sample root filesystem does not include:

```bash
sudo apt install gstreamer1.0-plugins-bad
```

## OpenCV with CUDA

The OpenCV that NVIDIA ships (4.5.4) is built **without** CUDA modules: `cv2.cuda.getCudaEnabledDeviceCount()` returns 0. To use the GPU from OpenCV you have to build it.

Build settings that mattered ([scripts/jetson/build_opencv_cuda.sh](../scripts/jetson/build_opencv_cuda.sh) has the full list):

```
-D WITH_CUDA=ON -D WITH_CUDNN=ON -D OPENCV_DNN_CUDA=ON
-D CUDA_ARCH_BIN=7.2 -D CUDA_ARCH_PTX=""        # 7.2 is Xavier
-D ENABLE_FAST_MATH=ON -D CUDA_FAST_MATH=ON -D WITH_CUBLAS=ON
-D WITH_GSTREAMER=ON -D WITH_V4L=ON -D WITH_TBB=ON
-D OPENCV_EXTRA_MODULES_PATH=<contrib>/modules
-D BUILD_opencv_python3=ON -D OPENCV_GENERATE_PKGCONFIG=ON
```

Practical notes:

- **Time:** 2 hours 5 minutes with 6 cores in the 20 W power mode. Most of the wall-clock tail is one or two huge CUDA source files that compile on a single core.
- **Memory:** peaked around 3.3 GB. An 8 GB swap file was added as a precaution and was never used.
- **Heat:** the SoC stayed at 50 °C for the whole build.
- **Install location:** `/usr/local`. The Python module lands in `/usr/local/lib/python3.8/site-packages`, which Ubuntu's Python does not search. Add a `.pth` file:

  ```bash
  echo /usr/local/lib/python3.8/site-packages | \
      sudo tee /usr/local/lib/python3.8/dist-packages/opencv-local.pth
  ```

- **Remove NVIDIA's OpenCV afterwards** so the two versions do not mix:

  ```bash
  sudo apt remove libopencv libopencv-dev libopencv-python libopencv-samples \
      opencv-licenses nvidia-opencv nvidia-opencv-dev
  sudo ldconfig
  ```

Verification:

- `cv2.cuda.getCudaEnabledDeviceCount()` returns 1.
- A 9x9 Gaussian filter on a 1080p image on the GPU matched the CPU result to within 1 grey level.
- A small ONNX network through `cv2.dnn` with the CUDA backend matched PyTorch's output (max difference 1e-7; 6e-4 with the FP16 target) and ran about 13 times faster than the CPU backend. That timing was taken while another build was using the CPU, so the CPU figure is pessimistic.

## Claude Code

Anthropic's Claude Code CLI runs on this board. The native installer picked the `linux-arm64` build; version 2.1.325 (the latest in November 2026) installed and started on Ubuntu 20.04 with glibc 2.31.

```bash
curl -fsSL https://claude.ai/install.sh | bash        # no sudo; installs under ~/.local
claude --version
claude doctor                                         # "No installation issues found."
```

`~/.local/bin` is added to `PATH` by Ubuntu's `~/.profile` at the next login. Signing in is interactive (`claude`, then `/login`). The check here went as far as `claude doctor` and the "Not logged in" reply to a prompt; a signed-in session was not tested by the author of these notes.

Over SSH it shows `Tip: Try setting environment variable COLORTERM=truecolor for richer colors`. SSH does not forward that variable, so set it on the Jetson for SSH sessions only (the physical console cannot show 24-bit colour):

```bash
# ~/.bashrc
if [ -n "$SSH_CONNECTION" ] && [ -z "$COLORTERM" ] && [ "$TERM" != linux ]; then
    export COLORTERM=truecolor
fi
```

## Python version

Everything GPU-related here is tied to Python 3.8:

| Component | Other Python versions? |
|---|---|
| NVIDIA PyTorch wheel | 3.8 only |
| TensorRT Python bindings | 3.8 only |
| OpenCV built here | Built against 3.8 |
| VPI | 3.8 and 3.9 packaged |
| CUDA, cuDNN, TensorRT from C++ | Not Python-dependent |

Options if you need something newer:

- A separate modern Python (pyenv, Miniforge) for work that does not need the GPU.
- Rebuilding PyTorch, torchvision, TensorRT bindings and OpenCV from source against another version. Many hours, not recommended without a concrete need.

Do not repoint the system `python3`. apt and NVIDIA's own tools depend on 3.8.

For project isolation use `python3 -m venv --system-site-packages`, so the virtual environment still sees the system-wide PyTorch, TensorRT and OpenCV.
