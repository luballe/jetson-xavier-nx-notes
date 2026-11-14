# Architecture notes

Background on what is inside the Xavier NX and how it changes the way you write code. These are reference notes, not measurements, except where stated.

## Engines on the SoC

Besides CPU and GPU the chip has several dedicated accelerators. The `ENG` page of jtop shows which are active.

| Engine | Purpose | How to reach it |
|---|---|---|
| CPU | 6 NVIDIA Carmel ARM cores | Everything general |
| GPU | 384 CUDA cores, Volta architecture | CUDA, PyTorch, TensorRT |
| DLA0, DLA1 | Two low-power neural-network inference accelerators | TensorRT, selecting a DLA core instead of the GPU |
| PVA | Classic computer-vision accelerator | VPI |
| NVENC | Hardware video encoder (H.264, H.265) | GStreamer `nvv4l2h264enc`, `nvv4l2h265enc` |
| NVDEC | Hardware video decoder | GStreamer `nvv4l2decoder` |
| NVJPG | JPEG encode/decode | GStreamer `nvjpegenc`, `nvjpegdec` |
| VIC | Scaling, colour conversion, composition | GStreamer `nvvidconv` |
| ISP | Processes raw CSI camera frames | `nvarguscamerasrc` |

Why this matters for a compute node:

- A network can run on a DLA while the GPU does something else, or three models can run at once (GPU, DLA0, DLA1). DLAs are slower than the GPU and do not support every layer type.
- Video decode and encode cost neither CPU nor GPU, so a camera → decode → inference → encode pipeline spreads across four engines.

## One pool of memory

CPU, GPU and DLA share the same 8 GB of RAM. There is no separate video memory.

On a desktop with a discrete GPU, data has to be copied from system RAM to VRAM over PCIe and back. On a Jetson the same physical memory is visible to both sides, so the copy can be avoided. It is not avoided automatically.

### The copy still happens if you write desktop-style code

`cudaMalloc` plus `cudaMemcpy` allocates a second buffer and copies within the same RAM. It works, and it wastes memory and time.

### Ways to avoid it

| Level | Mechanism | Effect |
|---|---|---|
| CUDA C/C++ | `cudaMallocManaged` (unified memory) | One pointer valid on CPU and GPU |
| CUDA C/C++ | `cudaHostAlloc` with `cudaHostAllocMapped` | Pinned host memory the GPU reads directly |
| OpenCV CUDA | `cv::cuda::HostMem` with `SHARED` allocation | One image usable as `Mat` and as `GpuMat`, no `upload()`/`download()` |
| Video and cameras | `NVMM` buffers in GStreamer | A frame goes from camera or decoder through scaling to inference without being copied |

The video path is where this pays off most. Pulling a frame down into ordinary CPU memory (a NumPy array, for example) is a copy.

### PyTorch

`tensor.to("cuda")` still allocates and copies. Two habits help on a Jetson:

- Load models straight to the GPU (`map_location="cuda"`) so the weights are not held twice during loading.
- Create tensors on the GPU (`device="cuda"`) where possible.

### The downside

- GPU allocations come out of system memory and the other way round. A large model and a heavy CPU process compete for the same 8 GB.
- Running out of memory ends with the kernel killing a process, not with a clean "out of VRAM" error.
- Unified memory has a small cache-synchronisation cost each time data changes hands between CPU and GPU.

This is why running headless helps twice: memory not spent on a desktop is available to the GPU as well.

## Cameras

The Xavier NX developer kit supports the Raspberry Pi Camera v2 (IMX219 sensor) out of the box. The v1 camera (OV5647) does not work. The HQ camera (IMX477) needs extra configuration.
