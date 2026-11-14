# PyTorch returns NaN on the CPU: the OpenBLAS 0.3.8 problem

A case study of one bug: how it showed up, how it was narrowed down, and the fix.

**Summary.** On a Jetson Xavier NX with JetPack 5 (Ubuntu 20.04), NVIDIA's PyTorch 2.1 wheel gives NaN results for multi-threaded work on the **CPU**. The GPU is not affected. The cause is the OpenBLAS 0.3.8 that Ubuntu 20.04 ships and that the wheel loads at run time. Replacing it with OpenBLAS 0.3.28 built from source fixes it.

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
| `OMP_NUM_THREADS=1` | Both symptoms disappear. So: a threading problem, not bad arithmetic in one kernel |
| `OPENBLAS_CORETYPE=ARMV8` (generic kernels instead of the auto-detected CPU type) | No change |
| OpenBLAS 0.3.8 pthread to 0.3.8 OpenMP | Symptom 1 gone, symptom 2 appears |
| Forward hooks on every ResNet-18 layer, to find the first layer that produces NaN | The NaN went away with the hooks attached. Timing-dependent, which again points to a race |
| Turning off NNPACK in PyTorch | Not possible: this build has no `torch.backends.nnpack` switch |
| OpenBLAS 0.3.28 built from source, OpenMP | Both symptoms gone |

The exact defect in 0.3.8 was not tracked down. The evidence says it is a thread-safety bug in that version on this CPU (NVIDIA Carmel, ARMv8.2) that later releases fixed. That is an inference from the table above, not something confirmed in the OpenBLAS source.

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

- `libblas.so.3` and `liblapack.so.3` have their own alternatives and still point at the 0.3.8 files. Software linked against those names, such as the OpenCV built in [03-software-stack.md](03-software-stack.md) for its LAPACK calls, was not tested for this problem.
- Speed was not compared between 0.3.8 and the generic-target 0.3.28. The CPU is the slow path on this board anyway.

## Workaround without building anything

`OMP_NUM_THREADS=1` gives correct results with the stock library, at the cost of using one core for CPU math.

## Tests that guard against it

In [tests/test_python_stack.py](../tests/test_python_stack.py):

| Test | Catches |
|---|---|
| `torch_cpu_blas_first_call` | Symptom 1. It runs first in its process on purpose, because only the first product fails |
| `torchvision_resnet18_gpu_matches_cpu` | Symptom 2. It reports separately whether the NaN is on the CPU or the GPU side |
| `torch_cpu_multithread_convnet` | Multi-threaded against single-threaded CPU results. A general guard; it did not reproduce this particular bug |

Each group of Python tests runs in a fresh process, which is what makes the "first call" test meaningful.

## Does this affect other boards?

Likely any Jetson on JetPack 5 with NVIDIA's PyTorch wheel and the apt OpenBLAS, since the software is identical, but it was only observed on one Xavier NX. Run the two reproductions above to find out.

## Verified across reboots

After the fix the board was rebooted twice in a row and the full suite was run after each boot: 65 passed, 0 failed, 1 skipped (no camera attached) both times, with `libopenblas.so.0` still resolving to `/opt/OpenBLAS`.
