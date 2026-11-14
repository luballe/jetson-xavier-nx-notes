# Test suite

A way to check that a Jetson Xavier NX set up as described in this repository actually works: every accelerator on the chip is made to compute something, and the result is compared with a reference.

It is written for Jetson Linux 35.x (JetPack 5) on a Xavier NX. Most of it should run on other Jetsons; the DLA and PVA tests skip or fail where the hardware is absent.

## Running it

```bash
git clone https://github.com/luballe/jetson-xavier-nx-notes
cd jetson-xavier-nx-notes/tests
./run_all.sh              # everything; uses sudo -n for a few read-only checks
./run_all.sh --no-sudo    # skip the checks that need root
```

- Takes about 4 minutes, plus about a minute to compile the native tests the first time.
- Changes no settings and writes only to a temporary directory.
- Prints one line per test (`PASS`, `FAIL` or `SKIP`, the test name, a detail) and a summary. The exit code is 0 when nothing failed.
- A `SKIP` means a requirement is missing (no camera, a package not installed) and says which.

Individual pieces:

```bash
python3 test_python_stack.py tensorrt      # only the Python tests whose name starts with a word
make -C native && native/cuda_libs         # one native program
VERBOSE=1 python3 test_python_stack.py vpi # with tracebacks
```

## What is tested

| Area | Engine | Test | How it is checked |
|---|---|---|---|
| System | - | Release, model, root device, cores online, power mode, temperature, free memory, boot slots, failed systemd units | Read from the system |
| Storage | NVMe | SMART warnings and media errors; PCIe AER errors, controller resets and I/O errors since boot; link speed | Kernel log and `nvme smart-log` |
| C | CPU | OpenMP threads on every core; parallel reduction; NEON SIMD dot product | Closed form / scalar code |
| CUDA | GPU | Device properties; kernel on unified memory; zero-copy on pinned host memory | Exact values |
| CUDA | GPU | cuBLAS matrix product; cuFFT forward and inverse; cuRAND statistics | CPU triple loop / round trip / expected mean |
| C++ | GPU | cuDNN convolution | Exact expected output |
| C++ | GPU, DLA0, DLA1 | TensorRT engine built with the C++ API, run on each device | Exact expected output, and the layer must really be placed on the DLA |
| C++ | GPU | OpenCV CUDA Gaussian filter; `HostMem::SHARED` zero-copy | CPU filter / exact values |
| C | CPU, GPU, PVA | VPI box filter on each backend | CPU backend |
| Python | CPU | Multi-threaded BLAS in PyTorch: first matrix product, and a conv net against its single-threaded result | NumPy / one thread |
| Python | GPU | PyTorch matrix product, cuDNN convolution, half precision, a training loop, allocator accounting | NumPy / CPU PyTorch |
| Python | GPU | torchvision compiled CUDA operator (NMS); ResNet-18 forward | Known answer / CPU |
| Python | GPU, DLA0, DLA1 | TensorRT engines from an ONNX file exported by PyTorch (FP32, FP16, DLA) | PyTorch output |
| Python | GPU | OpenCV CUDA filter, colour conversion, resize; `cv2.dnn` on the CUDA backend | CPU OpenCV / PyTorch output |
| Python | GPU, PVA | VPI box filter | CPU backend |
| GStreamer | VIC | 1080p to 720p scaling and colour conversion in hardware buffers | Output size |
| GStreamer | NVENC, NVDEC | H.264 and H.265: encode 90 frames, decode them back | Frame count |
| GStreamer | NVJPG | JPEG encode and decode of a 1080p frame | JPEG header / frame size |
| GStreamer | ISP | 30 frames from a CSI camera | Frame count; skipped with no camera |
| Board | - | Ethernet link, USB host, I2C buses, GPIO controllers, fan PWM | Presence only |

Not covered: audio, CAN, UART, SPI, display output and Wi-Fi/Bluetooth. They need external hardware or a loopback to test meaningfully.

A complete run on the board this repository describes is in [sample_output.txt](sample_output.txt): 65 passed, 0 failed, 1 skipped (no camera attached).

This suite found two real problems during development, both documented in docs/03: NaN results from PyTorch on the CPU caused by the distribution's OpenBLAS, and video parsers missing from the default installation.

## Requirements

Everything in [docs/03-software-stack.md](../docs/03-software-stack.md), plus:

```bash
sudo apt install build-essential nvme-cli pciutils gstreamer1.0-plugins-bad
sudo -H python3 -m pip install onnx
```

`gstreamer1.0-plugins-bad` provides `h264parse` and `h265parse`. `onnx` is needed by PyTorch's ONNX exporter.

## Reading failures

| Failure | Likely cause |
|---|---|
| `torch_cpu_blas_first_call` or `torchvision_resnet18_gpu_matches_cpu`: NaN in the CPU result | Ubuntu 20.04's OpenBLAS 0.3.8. Build a newer one, see docs/03 |
| `torch_cuda_available` | A CPU-only PyTorch from PyPI instead of NVIDIA's wheel |
| `opencv_built_with_cuda` | NVIDIA's stock OpenCV, which has no CUDA modules |
| `tensorrt_*_dla*`: fell back to GPU | The network has a layer the DLA does not support |
| Out-of-memory errors in several tests | Something else is using RAM; the GPU shares it. Close the desktop or other jobs and rerun |
| `nvme_link_errors` | PCIe link errors with this SSD, see docs/02 |
| `nvenc_*` skipped | `gstreamer1.0-plugins-bad` not installed |

## Notes on tolerances

- FP16 results are compared with a looser tolerance than FP32.
- The PVA backend of VPI gives box-filter results a few grey levels below the CPU and CUDA backends (mean difference about 3 on a random image). The tests accept up to 8.
- Timings printed in the details are indicative only.

## Files

| File | Language | Contents |
|---|---|---|
| `run_all.sh` | Bash | Driver: system, storage, GStreamer and interface checks; builds and runs the rest |
| `test_python_stack.py` | Python | PyTorch, torchvision, TensorRT, OpenCV, VPI |
| `native/cpu_openmp_neon.c` | C | OpenMP and NEON |
| `native/cuda_basics.cu` | CUDA | Unified memory and zero-copy |
| `native/cuda_libs.cu` | CUDA | cuBLAS, cuFFT, cuRAND |
| `native/cudnn_conv.cpp` | C++ | cuDNN |
| `native/tensorrt_engine.cpp` | C++ | TensorRT on GPU and DLA |
| `native/opencv_cuda.cpp` | C++ | OpenCV CUDA |
| `native/vpi_backends.c` | C | VPI on CPU, CUDA, PVA |

All test code here was written for this repository.
