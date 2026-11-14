# PyTorch returns NaN on the CPU: the OpenBLAS 0.3.8 problem

A case study of one bug: how it showed up, how it was narrowed down, and the fix.

**Summary.** On a Jetson Xavier NX with JetPack 5 (Ubuntu 20.04), NVIDIA's PyTorch 2.1 wheel gives NaN results for multi-threaded work on the **CPU**. The GPU is not affected. The cause is the OpenBLAS 0.3.8 that Ubuntu 20.04 ships and that the wheel loads at run time: it does not recognise this board's CPU and falls back to generic routines that are broken in that version. Replacing it with OpenBLAS 0.3.28 built from source fixes it; so does telling 0.3.8 to use its Cortex-A57 routines.

## Why it is easy to miss

- Everything on the GPU is correct, and the GPU is what people check after installing PyTorch on a Jetson.
- NumPy from pip is correct too. It bundles its own OpenBLAS and never touches the system one.
- With the default (pthread) OpenBLAS only the *first* matrix product in a process is wrong. A second attempt in the same Python session gives the right answer.
- Nothing crashes and nothing is logged. The result is just NaN.

A typical way to get hurt: a test that compares GPU output against a CPU reference fails, and the GPU gets the blame.

## How it was found

The test suite in [tests/](../tests/) checks every GPU result against a CPU reference. On its first run two things looked wrong:

1. A 1024x1024 matrix product on the GPU "did not match" the CPU. The GPU result was right; the CPU result was all NaN.
2. After the first attempt at a fix, a ResNet-18 forward pass on the GPU "did not match" the CPU. Again the CPU side was NaN.

## What PyTorch is linked to

```bash
$ ldd /usr/local/lib/python3.8/dist-packages/torch/lib/libtorch_cpu.so | grep -E "blas|gomp"
    libopenblas.so.0 => /lib/aarch64-linux-gnu/libopenblas.so.0
    libgomp.so.1     => /lib/aarch64-linux-gnu/libgomp.so.1
```

So the wheel does not carry its own BLAS. It uses whatever `libopenblas.so.0` the system provides, and on Ubuntu that file is chosen by `update-alternatives`:

```bash
$ update-alternatives --display libopenblas.so.0-aarch64-linux-gnu
/usr/lib/aarch64-linux-gnu/openblas-pthread/libopenblas.so.0 - priority 100   # default
/usr/lib/aarch64-linux-gnu/openblas-openmp/libopenblas.so.0  - priority 95
```

Both come from OpenBLAS `0.3.8+ds-1ubuntu0.20.04.1`. NVIDIA's install instructions for the wheel ask for `libopenblas-dev`, which selects the pthread build.

## Symptom 1: pthread build, first matrix product is NaN

```python
import torch
a = torch.rand(1024, 1024)
print(torch.isnan(a @ a).any())     # tensor(True)
print(torch.isnan(a @ a).any())     # tensor(False)
```

Only the first multi-threaded product in the process fails. Later ones are correct.

## Symptom 2: OpenMP build, ResNet-18 is NaN

Switching the alternative to the OpenMP build of the same version (`libopenblas0-openmp`) made the matrix product correct. PyTorch itself uses OpenMP (`libgomp`), so two threading runtimes fighting each other looked like a plausible cause, and this looked like the fix.

It was not. With the OpenMP build:

```python
import torch, torchvision
m = torchvision.models.resnet18().eval()
x = torch.rand(1, 3, 224, 224)
with torch.no_grad():
    print(torch.isnan(m(x)).any())  # tensor(True), every time
```

A smaller hand-made stack of convolutions did not reproduce it; ResNet-18 did, on every run.

## What was tried

| Experiment | Result |
|---|---|
| `OMP_NUM_THREADS=1` | Both symptoms disappear in PyTorch. This suggested a threading problem, which turned out to be misleading (see the root cause below) |
| `OPENBLAS_CORETYPE=ARMV8` | No change. In hindsight that is expected: generic ARMV8 is what the library was already using |
| `OPENBLAS_CORETYPE=CORTEXA57` (or `CORTEXA72`) with the stock 0.3.8 | Both symptoms gone, in both builds, 4 runs out of 4 |
| `OPENBLAS_CORETYPE=CORTEXA53` | Still wrong |
| OpenBLAS 0.3.8 pthread to 0.3.8 OpenMP | Symptom 1 gone, symptom 2 appears |
| Forward hooks on every ResNet-18 layer, to find the first layer that produces NaN | The NaN went away with the hooks attached |
| Turning off NNPACK in PyTorch | Not possible: this build has no `torch.backends.nnpack` switch |
| OpenBLAS 0.3.28 built from source, OpenMP | Both symptoms gone |

## Root cause

Ubuntu's OpenBLAS is built to pick its routines at run time from the CPU model. The Xavier NX CPU is NVIDIA's own Carmel core (`CPU implementer 0x4e`, `CPU part 0x004`), which 0.3.8 does not know:

```bash
$ OPENBLAS_VERBOSE=2 python3 -c "import ctypes; ctypes.CDLL('/usr/lib/aarch64-linux-gnu/openblas-pthread/libopenblas.so.0')"
Falling back to generic ARMV8 core
Core: armv8
```

The generic ARMV8 routines in 0.3.8 give wrong results on this board. Calling the library directly, with no PyTorch involved, shows it. A plain `sgemm`/`dgemm` of two random n x n matrices returns NaN in part of the output, the same count on every run:

| n | NaN elements, default threads | NaN elements, 1 thread |
|---|---|---|
| 4 | 0 | 0 |
| 64 | 256 | 256 |
| 256 | 512 | 4096 |
| 1024 | 10240 | 65536 |

The elements that are not NaN are correct. With `OPENBLAS_CORETYPE=CORTEXA57` the same calls return no NaN at all.

So this is not a race between threads, as the first experiments suggested. It is deterministic, it happens with one thread, and it depends only on which set of routines the library selects. Why the NaN shows up in only some PyTorch calls (the first product, or ResNet-18 but not a smaller network) was not explained.

What was not done: finding the faulty routine in the OpenBLAS 0.3.8 source. OpenBLAS 0.3.28 built with `TARGET=ARMV8` uses that version's generic routines and is correct.

## The fix

Build a current OpenBLAS with OpenMP threading and register it as the system `libopenblas.so.0`. Script: [scripts/jetson/build_openblas.sh](../scripts/jetson/build_openblas.sh). About 15 minutes on the board.

```bash
wget https://github.com/OpenMathLib/OpenBLAS/archive/refs/tags/v0.3.28.tar.gz
tar xf v0.3.28.tar.gz && cd OpenBLAS-0.3.28
make -j6 USE_OPENMP=1 TARGET=ARMV8 NUM_THREADS=16
sudo make install PREFIX=/opt/OpenBLAS USE_OPENMP=1 TARGET=ARMV8 NUM_THREADS=16
sudo update-alternatives --install /usr/lib/aarch64-linux-gnu/libopenblas.so.0 \
    libopenblas.so.0-aarch64-linux-gnu /opt/OpenBLAS/lib/libopenblas.so.0 200
sudo update-alternatives --set libopenblas.so.0-aarch64-linux-gnu /opt/OpenBLAS/lib/libopenblas.so.0
sudo ldconfig
```

Why these choices:

| Choice | Reason |
|---|---|
| `USE_OPENMP=1` | PyTorch already runs on `libgomp`; one thread pool instead of two |
| `TARGET=ARMV8` | Generic ARMv8 kernels. Slower than a tuned target would be, but it avoids CPU auto-detection on a core that OpenBLAS has no specific support for |
| `PREFIX=/opt/OpenBLAS` | Nothing from apt is overwritten |
| `update-alternatives` | The Ubuntu packages stay installed, PyTorch needs no rebuild, and it is one command to undo |

Check and undo:

```bash
readlink -f /usr/lib/aarch64-linux-gnu/libopenblas.so.0     # /opt/OpenBLAS/lib/libopenblas.so.0
sudo update-alternatives --config libopenblas.so.0-aarch64-linux-gnu
```

The setting survives reboots.

## What was not changed

- `libblas.so.3` and `liblapack.so.3` have their own alternatives and still point at the 0.3.8 files. They were tested afterwards; see the next section.
- Speed was not compared between 0.3.8 and the generic-target 0.3.28. The CPU is the slow path on this board anyway.

## The other BLAS files: `libblas.so.3`, `liblapack.so.3` and OpenCV

On Ubuntu these are separate alternatives from `libopenblas.so.0`, and here they still resolve to the 0.3.8 pthread build.

**Called directly** (ctypes, Fortran interface, NumPy as the reference):

| Library | `sgemm`/`dgemm` | `dgesv`, `dpotrf`, `dgesdd` at n=64 and n=800 |
|---|---|---|
| System `libblas.so.3` / `liblapack.so.3` (0.3.8) | **NaN** for n >= 16 (table above) | Correct |
| Same with `OPENBLAS_CORETYPE=CORTEXA57` | Correct | Correct |
| Reference BLAS/LAPACK (netlib) | Correct | Correct |
| OpenBLAS 0.3.28 in `/opt/OpenBLAS` | Correct | Correct |

So any program that links `-lblas` on this system and multiplies matrices gets NaN. That is still the state of this board: the `libblas.so.3` alternative was not changed.

**Through OpenCV.** The OpenCV built here does not use those matrix products. `LD_DEBUG=bindings` shows where its calls go:

| OpenCV call | Resolves to |
|---|---|
| `cblas_dgemm` (`cv2.gemm`) | `libcblas.so.3` from ATLAS (`libatlas3-base`), not OpenBLAS |
| `dgesv_`, `dgetrf_`, `dgesdd_`, ... (`cv2.solve`, `cv2.invert`, `cv2.SVDecomp`) | `liblapack.so.3`, the 0.3.8 file |

Tested against NumPy in float32 and float64, at n = 8, 100 and 600 (1000 for `gemm`): `cv2.gemm`, `cv2.solve` with LU, Cholesky, SVD and QR, `cv2.invert`, `cv2.SVDecomp`, `cv2.eigen`, and `cv2.findHomography`. All 49 checks passed in 5 fresh processes and with 4 Python threads running them at once. OpenCV on this board is not affected.

Pointing `liblapack.so.3` at the 0.3.28 library for one process (`LD_LIBRARY_PATH` with a symlink) and repeating the OpenCV checks also passed, so switching the two alternatives to `/opt/OpenBLAS` would be safe for OpenCV. It was not done here.

## Workaround without building anything

```bash
export OPENBLAS_CORETYPE=CORTEXA57
```

With that variable set, the stock 0.3.8 gave correct results in every check above. It has to reach every process that uses the library (shell profile, systemd units, cron jobs), which is why replacing the library was preferred here.

`OMP_NUM_THREADS=1` hid the problem in PyTorch but not in direct calls to the library, so it is not a fix.

## Tests that guard against it

In [tests/test_python_stack.py](../tests/test_python_stack.py):

| Test | Catches |
|---|---|
| `torch_cpu_blas_first_call` | Symptom 1. It runs first in its process on purpose, because only the first product fails |
| `torchvision_resnet18_gpu_matches_cpu` | Symptom 2. It reports separately whether the NaN is on the CPU or the GPU side |
| `torch_cpu_multithread_convnet` | Multi-threaded against single-threaded CPU results. A general guard; it did not reproduce this particular bug |
| `opencv_linear_algebra_matches_numpy` | OpenCV's own BLAS/LAPACK path, which uses different library files |

Each group of Python tests runs in a fresh process, which is what makes the "first call" test meaningful.

## Does this affect other boards?

Likely any Jetson on JetPack 5 with NVIDIA's PyTorch wheel and the apt OpenBLAS, since the software is identical, but it was only observed on one Xavier NX. Run the two reproductions above to find out.

## Verified across reboots

After the fix the board was rebooted twice in a row and the full suite was run after each boot: 65 passed, 0 failed, 1 skipped (no camera attached) both times (66 since the OpenCV linear-algebra test was added), with `libopenblas.so.0` still resolving to `/opt/OpenBLAS`.
