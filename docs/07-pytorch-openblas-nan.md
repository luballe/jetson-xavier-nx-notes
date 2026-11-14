# NaN from the CPU math library: the OpenBLAS 0.3.8 problem

A case study of one bug: how it showed up, the wrong turn taken while diagnosing it, the root cause, and the fix.

**Summary.** On a Jetson Xavier NX with JetPack 5 (Ubuntu 20.04), the system OpenBLAS (0.3.8) returns NaN from plain matrix products on the **CPU**. It does not recognise this board's Carmel CPU and falls back to generic routines that are broken in that version. NVIDIA's PyTorch wheel loads that library, so PyTorch gives NaN on the CPU; so does any program linked with `-lblas`. The GPU is not affected. The fix used here: build OpenBLAS 0.3.28 and point every system BLAS/LAPACK alternative at it. A workaround with no build: `export OPENBLAS_CORETYPE=CORTEXA57`.

## Why it is easy to miss

- Everything on the GPU is correct, and the GPU is what people check after installing PyTorch on a Jetson.
- NumPy from pip is correct too. It bundles its own OpenBLAS and never touches the system one.
- In PyTorch with the default library only the *first* matrix product in a process is wrong. A second attempt in the same Python session gives the right answer.
- Nothing crashes and nothing is logged. The result is just NaN.

A typical way to get hurt: a test that compares GPU output against a CPU reference fails, and the GPU gets the blame.

## How it was found and fixed, in order

### 1. A GPU test failed, and the GPU was innocent

The test suite in [tests/](../tests/) checks every GPU result against a CPU reference. On its first run a 1024x1024 matrix product on the GPU "did not match" the CPU. Comparing both against NumPy showed the GPU was right and the CPU result contained NaN.

```python
import torch
a = torch.rand(1024, 1024)
print(torch.isnan(a @ a).any())     # tensor(True)
print(torch.isnan(a @ a).any())     # tensor(False)
```

Only the first product in the process failed.

### 2. Which library is doing the CPU math

```bash
$ ldd /usr/local/lib/python3.8/dist-packages/torch/lib/libtorch_cpu.so | grep -E "blas|gomp"
    libopenblas.so.0 => /lib/aarch64-linux-gnu/libopenblas.so.0
    libgomp.so.1     => /lib/aarch64-linux-gnu/libgomp.so.1
```

The wheel does not carry its own BLAS. It uses whatever `libopenblas.so.0` the system provides, and on Ubuntu that file is chosen by `update-alternatives`:

```bash
$ update-alternatives --display libopenblas.so.0-aarch64-linux-gnu
/usr/lib/aarch64-linux-gnu/openblas-pthread/libopenblas.so.0 - priority 100   # default
/usr/lib/aarch64-linux-gnu/openblas-openmp/libopenblas.so.0  - priority 95
```

Both come from OpenBLAS `0.3.8+ds-1ubuntu0.20.04.1`. NVIDIA's install instructions for the wheel ask for `libopenblas-dev`, which selects the pthread build.

### 3. First hypothesis: a threading problem (wrong)

`OMP_NUM_THREADS=1` made the NaN disappear, so it looked like a threading bug. PyTorch uses OpenMP (`libgomp`) and the default OpenBLAS uses its own pthread pool, so two thread pools fighting each other was a plausible story.

Switching the alternative to the OpenMP build of the same 0.3.8 made the matrix product correct. That looked like the fix.

### 4. The "fix" moved the problem

With the OpenMP build, the suite then failed somewhere else:

```python
import torch, torchvision
m = torchvision.models.resnet18().eval()
x = torch.rand(1, 3, 224, 224)
with torch.no_grad():
    print(torch.isnan(m(x)).any())  # tensor(True), every time
```

More experiments, none conclusive:

| Experiment | Result |
|---|---|
| `OMP_NUM_THREADS=1` | NaN gone |
| `OPENBLAS_CORETYPE=ARMV8` | No change |
| A smaller hand-made stack of convolutions | No NaN; only ResNet-18 reproduced it |
| Forward hooks on every ResNet-18 layer, to find the first layer that produces NaN | The NaN went away with the hooks attached |
| Turning off NNPACK in PyTorch | Not possible: this build has no `torch.backends.nnpack` switch |

A result that vanishes when you observe it fits a race, so the threading hypothesis survived.

### 5. A newer OpenBLAS fixed PyTorch

OpenBLAS 0.3.28 was built from source and registered as `libopenblas.so.0`. Both PyTorch symptoms disappeared and the suite passed. At this point the write-up said "probably a thread-safety bug in 0.3.8", which was an inference, not a finding.

### 6. Testing the other BLAS files exposed the real cause

Ubuntu has three separate run-time alternatives: `libopenblas.so.0`, `libblas.so.3` and `liblapack.so.3`. Only the first had been switched. To check the other two, the libraries were called directly from Python with ctypes, with no PyTorch involved and NumPy as the reference.

A plain `sgemm`/`dgemm` of two random n x n matrices through the 0.3.8 `libblas.so.3`:

| n | NaN elements, default threads | NaN elements, 1 thread |
|---|---|---|
| 4 | 0 | 0 |
| 64 | 256 | 256 |
| 256 | 512 | 4096 |
| 1024 | 10240 | 65536 |

Same counts on every run. The elements that are not NaN are correct. The reference BLAS (netlib) and OpenBLAS 0.3.28 pass the same test, so the harness is not at fault.

This cannot be a race: it is deterministic and it happens with **one thread**.

### 7. Root cause: an unrecognised CPU

Ubuntu's OpenBLAS picks its routines at run time from the CPU model. The Xavier NX CPU is NVIDIA's own Carmel core (`CPU implementer 0x4e`, `CPU part 0x004`), which 0.3.8 does not know:

```bash
$ OPENBLAS_VERBOSE=2 python3 -c "import ctypes; ctypes.CDLL('/usr/lib/aarch64-linux-gnu/openblas-pthread/libopenblas.so.0')"
Falling back to generic ARMV8 core
Core: armv8
```

Forcing a different set of routines in the same 0.3.8 binary settles it:

| `OPENBLAS_CORETYPE` | Direct `gemm` | PyTorch matrix product (pthread build) | PyTorch ResNet-18 (OpenMP build) |
|---|---|---|---|
| unset (falls back to ARMV8) | NaN | NaN on first call | NaN |
| `ARMV8` | NaN | NaN | NaN |
| `CORTEXA53` | NaN | not tested | not tested |
| `CORTEXA57` | Correct | Correct, 4 runs of 4 | Correct, 4 runs of 4 |
| `CORTEXA72` | Correct | not tested | not tested |

So the generic ARMV8 routines in OpenBLAS 0.3.8 give wrong results on this CPU, and that explains everything seen in PyTorch. It also explains why `OPENBLAS_CORETYPE=ARMV8` did nothing in step 4: that was already the selection.

Still unexplained: why PyTorch sees the NaN only in some calls (the first product, ResNet-18 but not a smaller network, not with one thread). The faulty routine in the 0.3.8 source was not located. OpenBLAS 0.3.28 built with `TARGET=ARMV8` uses that version's generic routines and is correct.

### 8. What about OpenCV?

The OpenCV built in [03-software-stack.md](03-software-stack.md) links `liblapack.so.3` and `libcblas.so.3`. `LD_DEBUG=bindings` shows where its calls go:

| OpenCV call | Resolved to |
|---|---|
| `cblas_dgemm` (`cv2.gemm`) | `libcblas.so.3` from ATLAS (`libatlas3-base`), not OpenBLAS |
| `dgesv_`, `dgetrf_`, `dgesdd_`, ... (`cv2.solve`, `cv2.invert`, `cv2.SVDecomp`) | `liblapack.so.3` |

Tested against NumPy in float32 and float64, at n = 8, 100 and 600 (1000 for `gemm`): `cv2.gemm`, `cv2.solve` with LU, Cholesky, SVD and QR, `cv2.invert`, `cv2.SVDecomp`, `cv2.eigen` and `cv2.findHomography`. All 49 checks passed with the 0.3.8 `liblapack.so.3`, in 5 fresh processes and with 4 Python threads at once, and passed again with 0.3.28.

OpenCV was never affected: its matrix products go to ATLAS, and the LAPACK routines of 0.3.8 (`dgesv`, `dpotrf`, `dgesdd` were also called directly at n=64 and n=800) return correct results even though its plain `gemm` does not.

### 9. Final fix: every alternative points at 0.3.28

Leaving `libblas.so.3` on 0.3.8 meant any program linked with `-lblas` would still get NaN. All BLAS/LAPACK alternatives now resolve to `/opt/OpenBLAS`:

| Alternative | Used for | Now points to |
|---|---|---|
| `libopenblas.so.0` | PyTorch at run time | `/opt/OpenBLAS/lib/libopenblas.so.0` |
| `libblas.so.3` | Programs linked with `-lblas` | same |
| `liblapack.so.3` | OpenCV, programs linked with `-llapack` | same |
| `libblas.so`, `liblapack.so`, `libopenblas.so` | Compiling: `-lblas`, `-llapack`, `-lopenblas`, `pkg-config`, `cblas.h` | `/opt/OpenBLAS/lib/libopenblas.so` and its headers |

`libcblas.so.3` is not an alternative on Ubuntu 20.04; it belongs to ATLAS, gives correct results and was left alone.

## The fix, as commands

[scripts/jetson/build_openblas.sh](../scripts/jetson/build_openblas.sh) does all of this. About 15 minutes on the board.

```bash
wget https://github.com/OpenMathLib/OpenBLAS/archive/refs/tags/v0.3.28.tar.gz
tar xf v0.3.28.tar.gz && cd OpenBLAS-0.3.28
make -j6 USE_OPENMP=1 TARGET=ARMV8 NUM_THREADS=16
sudo make install PREFIX=/opt/OpenBLAS USE_OPENMP=1 TARGET=ARMV8 NUM_THREADS=16

L=/usr/lib/aarch64-linux-gnu
for n in libopenblas.so.0 libblas.so.3 liblapack.so.3; do
  sudo update-alternatives --install $L/$n $n-aarch64-linux-gnu /opt/OpenBLAS/lib/libopenblas.so.0 200
  sudo update-alternatives --set $n-aarch64-linux-gnu /opt/OpenBLAS/lib/libopenblas.so.0
done
sudo ldconfig
```

The build-time alternatives carry headers, static libraries and pkg-config files as slave links; the script handles those.

| Choice | Reason |
|---|---|
| `USE_OPENMP=1` | PyTorch already runs on `libgomp`; one thread pool instead of two |
| `TARGET=ARMV8` | Fixed generic ARMv8 routines, no CPU detection at run time. Slower than a tuned target would be, but there is no Carmel target to pick |
| `PREFIX=/opt/OpenBLAS` | Nothing from apt is overwritten |
| `update-alternatives` | The Ubuntu packages stay installed, nothing needs a rebuild, and it can be undone |

Check and undo:

```bash
update-alternatives --get-selections | grep -i -E "blas|lapack"
sudo update-alternatives --auto libblas.so.3-aarch64-linux-gnu      # back to Ubuntu's choice; same for the others
```

One library provides BLAS and LAPACK together (it was built with gfortran, so LAPACK is included), which is why three names can point at one file.

## Workaround without building anything

```bash
export OPENBLAS_CORETYPE=CORTEXA57
```

With that variable set, the stock 0.3.8 gave correct results in every check above. It has to reach every process that uses the library (shell profile, systemd units, cron jobs), which is why replacing the library was preferred here.

`OMP_NUM_THREADS=1` hid the problem in PyTorch but not in direct calls to the library, so it is not a fix.

## Verification

After the final change:

- A C program compiled with `gcc ... -lblas -llapack` (and with `pkg-config --libs blas lapack`): `dgemm` with no NaN, `dgesv` correct, linked against `/opt/OpenBLAS`.
- The direct ctypes test passes through all three library names, and fails against the old files (256 NaN at n=64), so it does detect the bug.
- OpenCV linear algebra and both PyTorch reproductions pass.
- Full suite after a reboot: 67 passed, 0 failed, 1 skipped (no camera attached). See [tests/sample_output.txt](../tests/sample_output.txt).

## Tests that guard against it

In [tests/test_python_stack.py](../tests/test_python_stack.py):

| Test | Catches |
|---|---|
| `numpy_system_blas_lapack_direct` | The root cause: `sgemm`, `dgemm` and `dgesv` called directly through `libblas.so.3`, `liblapack.so.3` and `libopenblas.so.0` |
| `torch_cpu_blas_first_call` | The first PyTorch symptom. It runs first in its process on purpose, because only the first product fails |
| `torchvision_resnet18_gpu_matches_cpu` | The second PyTorch symptom. It reports separately whether the NaN is on the CPU or the GPU side |
| `torch_cpu_multithread_convnet` | Multi-threaded against single-threaded CPU results. A general guard; it did not reproduce this bug |
| `opencv_linear_algebra_matches_numpy` | OpenCV's own BLAS/LAPACK path |

Each group of Python tests runs in a fresh process, which is what makes the "first call" test meaningful.

## Lessons

- Compare both sides of a mismatch against a third reference before blaming either.
- "It goes away with one thread" and "it goes away when observed" suggested a race, and both were red herrings here. Calling the library directly, outside the framework, was what separated the library's fault from the framework's behaviour.
- Fixing the one file a failing program uses is not the same as fixing the system. Ubuntu's BLAS is three alternatives, plus three more for compiling.
- Check what a library selects at run time (`OPENBLAS_VERBOSE=2`). A CPU the library has never heard of is a risk on its own.

## Does this affect other boards?

Likely any Xavier-family Jetson (Carmel CPU) on JetPack 5 with the apt OpenBLAS, since the software and CPU core are the same, but it was only observed on one Xavier NX. The quickest check:

```bash
OPENBLAS_VERBOSE=2 python3 -c "import torch; a = torch.rand(1024, 1024); print(torch.isnan(a @ a).any())"
```

## Not done

- Locating the defect in the OpenBLAS 0.3.8 source, or the release that fixed it.
- Comparing speed between 0.3.8 with `CORTEXA57` routines and the generic-target 0.3.28.
