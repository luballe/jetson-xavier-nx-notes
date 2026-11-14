# Jetson Xavier NX notes

Field notes from bringing a 2020 NVIDIA Jetson Xavier NX Developer Kit back to life in November 2026 and turning it into a small headless GPU compute node.

The board had been dead since a boot-device change years earlier. It now boots from an NVMe SSD only, runs the last software release NVIDIA made for it, and has a working CUDA stack with PyTorch, TensorRT, VPI and a CUDA-enabled OpenCV.

Everything here was done and verified on one specific unit. Treat it as a worked example, not as official guidance.

## Final state

| Item | Value |
|---|---|
| Hardware | Jetson Xavier NX Developer Kit (P3668-0000 module with microSD slot, P3509 carrier) |
| OS | Jetson Linux (L4T) 35.6.5 = JetPack 5.1.x, Ubuntu 20.04, kernel 5.10, Python 3.8 |
| Boot | UEFI in QSPI flash, root filesystem on NVMe (no microSD inserted) |
| SSD | SanDisk Optimus GX 7100 500 GB (the former WD Black SN7100), link at PCIe Gen4 x4 |
| Power mode | `MODE_20W_6CORE` (nvpmodel ID 8) |
| Desktop | Disabled (`multi-user.target`) |
| CUDA / cuDNN / TensorRT | 11.4 / 8.6.0 / 8.5.2 |
| PyTorch / torchvision | 2.1.0a0 (NVIDIA wheel `nv23.06`) / 0.16.1 built from source |
| OpenCV | 4.10.0 built from source with CUDA, cuDNN and contrib modules |
| VPI | 2.4.8 (CPU, CUDA and PVA backends) |
| BLAS / LAPACK | OpenBLAS 0.3.28 built from source, for the whole system (the distribution's 0.3.8 returns NaN on this CPU) |

JetPack 5 is the end of the line for Xavier NX. JetPack 6 does not support it.

## Documents

| File | What it covers |
|---|---|
| [docs/01-recovery-and-flashing.md](docs/01-recovery-and-flashing.md) | Reflashing a dead board from an Ubuntu host, every failure hit on the way, and the fix for each |
| [docs/02-nvme-ssd.md](docs/02-nvme-ssd.md) | A Samsung 970 EVO Plus that does not work in this board, how it was diagnosed, and moving the system from microSD to NVMe |
| [docs/03-software-stack.md](docs/03-software-stack.md) | Installing CUDA, cuDNN, TensorRT, VPI, PyTorch, torchvision, and building OpenCV with CUDA |
| [docs/04-headless-and-tuning.md](docs/04-headless-and-tuning.md) | Headless mode, disabled services, power modes, jtop, zram, and a harmless firmware-update loop |
| [docs/05-architecture-notes.md](docs/05-architecture-notes.md) | The hardware engines on the SoC and how shared CPU/GPU memory affects code |
| [docs/06-orin-upgrade-research.md](docs/06-orin-upgrade-research.md) | Whether an Orin NX module fits this carrier board, and November 2026 prices |
| [docs/07-pytorch-openblas-nan.md](docs/07-pytorch-openblas-nan.md) | NaN from CPU math (PyTorch and anything linked to the system BLAS) caused by Ubuntu's OpenBLAS 0.3.8: how it was found, the root cause and the fix |
| [scripts/](scripts/) | The scripts used, cleaned up |
| [tests/](tests/) | A test suite in C, C++, CUDA, Python and GStreamer that exercises every engine on the chip and checks the results |

## The short version of what went wrong

1. The board would not boot because the firmware in QSPI and the system on disk no longer matched. Reflashing from an x86 Ubuntu host in recovery mode fixed that.
2. The original SSD, a Samsung 970 EVO Plus 250 GB, produces PCIe link errors in this board's M.2 slot. The drive is healthy and the slot is healthy; the pairing is not. A different SSD in the same slot runs with zero errors.
3. Several "it powers off by itself" symptoms were not power or heat. They were a system hanging with no root filesystem, and later the UEFI falling back to a recovery kernel that did not exist.

## Checking your own board

```bash
git clone https://github.com/luballe/jetson-xavier-nx-notes
cd jetson-xavier-nx-notes/tests && ./run_all.sh
```

See [tests/README.md](tests/README.md) for what it covers and how to read failures.

## Conventions

- `host` means the x86-64 Ubuntu machine used for flashing (Ubuntu 24.04 here, although NVIDIA documents 18.04 and 20.04).
- `jetson` means the Xavier NX itself.
- Serial numbers, addresses and credentials are deliberately left out.
