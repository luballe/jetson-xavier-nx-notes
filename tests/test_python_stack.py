#!/usr/bin/env python3
"""Functional tests for the Python side of the Jetson GPU stack.

Each test computes something on an accelerator and compares it with a reference
computed another way, so a PASS means "produced the right numbers", not just
"imported". Run through run_all.sh, or directly:

    python3 test_python_stack.py            # all tests
    python3 test_python_stack.py torch vpi  # only tests whose name starts with a word

run_all.sh starts one process per group (numpy, cudnn, torch_, torchvision, tensorrt,
opencv, vpi): the accelerator runtimes are more reliable when they do not share a process.

Output: one line per test, "PASS|FAIL|SKIP  name  detail". Exit code 1 on any FAIL.
"""
import os
import sys
import tempfile
import time
import traceback

RESULTS = []
TESTS = []
TMP = tempfile.mkdtemp(prefix="jetson_tests_")


class Skip(Exception):
    pass


def test(fn):
    TESTS.append(fn)
    return fn


def need(module):
    try:
        return __import__(module)
    except Exception as e:  # ImportError, or a broken native library
        raise Skip("%s not available (%s)" % (module, str(e)[:60]))


def small_net():
    """A small conv net with fixed weights, used by several tests."""
    torch = need("torch")
    torch.manual_seed(0)
    return torch.nn.Sequential(
        torch.nn.Conv2d(3, 16, 3, padding=1), torch.nn.ReLU(),
        torch.nn.Conv2d(16, 16, 3, padding=1), torch.nn.ReLU(),
        torch.nn.Conv2d(16, 8, 3, padding=1),
    ).eval()


def export_onnx(name="net.onnx", shape=(1, 3, 224, 224)):
    """Export small_net to ONNX. Returns (path, input tensor, reference output)."""
    torch = need("torch")
    need("onnx")
    path = os.path.join(TMP, name)
    m = small_net()
    torch.manual_seed(1)
    x = torch.rand(*shape)
    with torch.no_grad():
        ref = m(x)
    if not os.path.exists(path):
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):     # the exporter prints a banner
            torch.onnx.export(m, x, path, opset_version=11,
                              input_names=["input"], output_names=["output"])
    return path, x, ref


# --------------------------------------------------------------------------- NumPy / cuDNN

@test
def numpy_version():
    np = need("numpy")
    return "numpy %s" % np.__version__


@test
def cudnn_library():
    import ctypes
    lib = ctypes.CDLL("libcudnn.so.8")
    lib.cudnnGetVersion.restype = ctypes.c_size_t
    v = lib.cudnnGetVersion()
    assert v >= 8000, "unexpected cuDNN version %d" % v
    return "cuDNN %d.%d.%d" % (v // 1000, (v // 100) % 10, v % 100)


# --------------------------------------------------------------------------- PyTorch

@test
def torch_cuda_available():
    torch = need("torch")
    assert torch.cuda.is_available(), "torch.cuda.is_available() is False (CPU-only build?)"
    return "torch %s on %s, cuDNN %s" % (
        torch.__version__, torch.cuda.get_device_name(0), torch.backends.cudnn.version())


@test
def torch_cpu_blas_first_call():
    """Must be the first CPU matrix product in the process.

    With Ubuntu 20.04's default OpenBLAS (0.3.8, pthread build) the first multi-threaded
    matrix product PyTorch makes returns NaN on this CPU. Fix: a newer OpenBLAS, see
    docs/07-pytorch-openblas-nan.md and scripts/jetson/build_openblas.sh.
    """
    torch = need("torch")
    np = need("numpy")
    torch.manual_seed(0)
    bad = []
    for i in range(5):
        a = torch.rand(1024, 1024)
        r = a @ a
        if torch.isnan(r).any().item():
            bad.append(i)
        elif i == 0:
            ref = a.numpy().astype(np.float64) @ a.numpy().astype(np.float64)
            err = float(np.abs(r.numpy() - ref).max() / ref.max())
            assert err < 1e-4, "relative error vs NumPy %.2e" % err
    assert not bad, ("NaN in CPU matrix product number %s: OpenBLAS threading bug, "
                     "see docs/07-pytorch-openblas-nan.md" % bad)
    return "5 CPU products of 1024x1024, no NaN, matches NumPy (%d threads)" % torch.get_num_threads()


@test
def torch_cpu_multithread_convnet():
    """A multi-threaded CPU forward pass must match the single-threaded one.

    A cheap guard against threading bugs in the BLAS library PyTorch is linked to.
    It did not reproduce the OpenBLAS 0.3.8 failure on its own; the ResNet-18 test in
    the torchvision group is the one that caught it.
    """
    torch = need("torch")
    torch.manual_seed(0)
    layers, c = [], 3
    for k, s, o in ((7, 2, 64), (3, 1, 64), (3, 2, 128), (1, 1, 128), (3, 2, 256), (3, 1, 256)):
        layers += [torch.nn.Conv2d(c, o, k, stride=s, padding=k // 2, bias=False), torch.nn.BatchNorm2d(o), torch.nn.ReLU()]
        c = o
    m = torch.nn.Sequential(*layers).eval()
    x = torch.rand(2, 3, 224, 224)
    n = torch.get_num_threads()
    with torch.no_grad():
        multi = [m(x) for _ in range(3)]
        torch.set_num_threads(1)
        single = m(x)
        torch.set_num_threads(n)
    assert not torch.isnan(single).any(), "NaN even single-threaded"
    nan = [i for i, r in enumerate(multi) if torch.isnan(r).any()]
    assert not nan, "NaN in multi-threaded CPU forward pass %s (%d threads): OpenBLAS threading bug" % (nan, n)
    err = max((r - single).abs().max().item() for r in multi)
    assert err < 1e-3, "multi-threaded result differs from single-threaded by %.2e" % err
    return "%d threads match 1 thread, max difference %.1e" % (n, err)


@test
def torch_matmul_gpu_matches_cpu():
    torch = need("torch")
    np = need("numpy")
    torch.manual_seed(0)
    a = torch.rand(1024, 1024)
    ref = a.numpy().astype(np.float64) @ a.numpy().astype(np.float64)   # NumPy as the reference
    gpu = (a.cuda() @ a.cuda()).cpu().numpy()
    err = float(np.abs(gpu - ref).max() / ref.max())
    assert err < 1e-4, "relative error %.2e" % err
    return "relative error %.1e" % err


@test
def torch_cudnn_conv_matches_cpu():
    torch = need("torch")
    m = small_net()
    torch.manual_seed(1)
    x = torch.rand(2, 3, 128, 128)
    with torch.no_grad():
        cpu = m(x)
        gpu = m.cuda()(x.cuda()).cpu()
    err = (cpu - gpu).abs().max().item()
    assert err < 1e-4, "max abs error %.2e" % err
    return "max abs error %.1e" % err


@test
def torch_half_precision():
    torch = need("torch")
    m = small_net()
    torch.manual_seed(1)
    x = torch.rand(1, 3, 128, 128)
    with torch.no_grad():
        ref = m(x)
        out = m.cuda().half()(x.cuda().half()).float().cpu()
    err = (ref - out).abs().max().item()
    assert err < 5e-2, "max abs error %.2e" % err
    return "FP16 max abs error %.1e" % err


@test
def torch_training_step():
    """Backward pass and optimizer step on the GPU; the loss must go down."""
    torch = need("torch")
    torch.manual_seed(0)
    m = torch.nn.Linear(64, 1).cuda()
    opt = torch.optim.SGD(m.parameters(), lr=0.01)
    x = torch.rand(256, 64, device="cuda")
    y = x.sum(dim=1, keepdim=True)
    first = last = None
    for _ in range(200):
        opt.zero_grad()
        loss = torch.nn.functional.mse_loss(m(x), y)
        loss.backward()
        opt.step()
        first = first if first is not None else loss.item()
        last = loss.item()
    assert last < first * 0.5, "loss %.3f -> %.3f" % (first, last)
    return "loss %.2f -> %.4f" % (first, last)


@test
def torch_memory_released():
    torch = need("torch")
    torch.cuda.empty_cache()
    before = torch.cuda.memory_allocated()
    t = torch.empty(256 * 1024 * 1024, dtype=torch.uint8, device="cuda")
    during = torch.cuda.memory_allocated()
    del t
    torch.cuda.empty_cache()
    after = torch.cuda.memory_allocated()
    assert during - before >= 256 * 1024 * 1024 and after <= before, "allocator accounting is off"
    return "256 MiB allocated and freed"


# --------------------------------------------------------------------------- torchvision

@test
def torchvision_nms_on_gpu():
    torch = need("torch")
    tv = need("torchvision")
    from torchvision.ops import nms
    boxes = torch.tensor([[0, 0, 10, 10], [1, 1, 11, 11], [50, 50, 60, 60]],
                         dtype=torch.float32, device="cuda")
    scores = torch.tensor([0.9, 0.8, 0.7], device="cuda")
    keep = nms(boxes, scores, 0.5).tolist()
    assert keep == [0, 2], "nms returned %s" % keep
    return "torchvision %s, compiled CUDA ops work" % tv.__version__


@test
def torchvision_resnet18_gpu_matches_cpu():
    torch = need("torch")
    tv = need("torchvision")
    torch.manual_seed(0)
    m = tv.models.resnet18().eval()
    x = torch.rand(1, 3, 224, 224)
    with torch.no_grad():
        cpu = m(x)
        gpu = m.cuda()(x.cuda()).cpu()
    assert not torch.isnan(gpu).any(), "NaN in the GPU result"
    assert not torch.isnan(cpu).any(), ("NaN in the CPU reference (GPU result is fine): "
                                        "OpenBLAS threading bug, see docs/07-pytorch-openblas-nan.md")
    err = (cpu - gpu).abs().max().item()
    assert err < 1e-3, "max abs error %.2e" % err
    return "max abs error %.1e" % err


# --------------------------------------------------------------------------- TensorRT

def trt_build_and_run(dla_core=None, fp16=False):
    """Build an engine from the ONNX net, run it, return (max error, info, dla layer count)."""
    torch = need("torch")
    trt = need("tensorrt")
    path, x, ref = export_onnx()
    logger = trt.Logger(trt.Logger.ERROR)
    builder = trt.Builder(logger)
    if dla_core is not None and builder.num_DLA_cores <= dla_core:
        raise Skip("this module reports %d DLA cores" % builder.num_DLA_cores)
    net = builder.create_network(1 << int(trt.NetworkDefinitionCreationFlag.EXPLICIT_BATCH))
    parser = trt.OnnxParser(net, logger)
    assert parser.parse(open(path, "rb").read()), "ONNX parse failed: %s" % parser.get_error(0)
    cfg = builder.create_builder_config()
    cfg.set_memory_pool_limit(trt.MemoryPoolType.WORKSPACE, 256 << 20)
    cfg.profiling_verbosity = trt.ProfilingVerbosity.DETAILED
    if fp16 or dla_core is not None:
        cfg.set_flag(trt.BuilderFlag.FP16)          # DLA needs FP16 or INT8
    if dla_core is not None:
        cfg.default_device_type = trt.DeviceType.DLA
        cfg.DLA_core = dla_core
        cfg.set_flag(trt.BuilderFlag.GPU_FALLBACK)
    t0 = time.time()
    plan = builder.build_serialized_network(net, cfg)
    assert plan is not None, "engine build failed"
    build_s = time.time() - t0
    engine = trt.Runtime(logger).deserialize_cuda_engine(plan)
    info = engine.create_engine_inspector().get_engine_information(trt.LayerInformationFormat.ONELINE)
    on_dla = info.count("ForeignNode")
    ctx = engine.create_execution_context()
    xin = x.cuda().contiguous()
    out = torch.empty(tuple(ref.shape), dtype=torch.float32, device="cuda")
    assert ctx.execute_v2([int(xin.data_ptr()), int(out.data_ptr())]), "execute_v2 failed"
    torch.cuda.synchronize()
    t0 = time.time()
    for _ in range(20):
        ctx.execute_v2([int(xin.data_ptr()), int(out.data_ptr())])
    torch.cuda.synchronize()
    ms = (time.time() - t0) / 20 * 1000
    err = (out.cpu() - ref).abs().max().item()
    return err, "build %.0fs, %.1f ms/inference" % (build_s, ms), on_dla


@test
def tensorrt_gpu_fp32_matches_pytorch():
    err, info, _ = trt_build_and_run()
    assert err < 1e-3, "max abs error %.2e" % err
    return "max abs error %.1e, %s" % (err, info)


@test
def tensorrt_gpu_fp16_matches_pytorch():
    err, info, _ = trt_build_and_run(fp16=True)
    assert err < 5e-2, "max abs error %.2e" % err
    return "max abs error %.1e, %s" % (err, info)


def _dla(core):
    err, info, on_dla = trt_build_and_run(dla_core=core)
    assert err < 5e-2, "max abs error %.2e" % err
    assert on_dla > 0, "engine built, but no layer was placed on the DLA (all fell back to GPU)"
    return "max abs error %.1e, %d DLA subgraph(s), %s" % (err, on_dla, info)


@test
def tensorrt_dla0_matches_pytorch():
    return _dla(0)


@test
def tensorrt_dla1_matches_pytorch():
    return _dla(1)


# --------------------------------------------------------------------------- OpenCV

@test
def opencv_built_with_cuda():
    cv2 = need("cv2")
    n = cv2.cuda.getCudaEnabledDeviceCount()
    assert n >= 1, "cv2.cuda sees %d devices: this OpenCV was built without CUDA" % n
    info = cv2.getBuildInformation()
    gst = any("GStreamer" in l and "YES" in l for l in info.splitlines())
    assert gst, "OpenCV was built without GStreamer"
    return "OpenCV %s, %d CUDA device, GStreamer yes" % (cv2.__version__, n)


@test
def opencv_cuda_filter_matches_cpu():
    cv2 = need("cv2")
    np = need("numpy")
    if cv2.cuda.getCudaEnabledDeviceCount() < 1:
        raise Skip("OpenCV has no CUDA support")
    rng = np.random.RandomState(0)
    img = (rng.rand(1080, 1920) * 255).astype(np.uint8)
    g = cv2.cuda_GpuMat()
    g.upload(img)
    f = cv2.cuda.createGaussianFilter(cv2.CV_8UC1, cv2.CV_8UC1, (9, 9), 2)
    gpu = f.apply(g).download()
    cpu = cv2.GaussianBlur(img, (9, 9), 2)
    diff = int(np.abs(gpu.astype(int) - cpu.astype(int)).max())
    assert diff <= 2, "max difference %d grey levels" % diff
    return "1080p Gaussian, max difference %d grey level(s)" % diff


@test
def opencv_cuda_resize_and_color():
    cv2 = need("cv2")
    np = need("numpy")
    if cv2.cuda.getCudaEnabledDeviceCount() < 1:
        raise Skip("OpenCV has no CUDA support")
    rng = np.random.RandomState(0)
    img = (rng.rand(720, 1280, 3) * 255).astype(np.uint8)
    g = cv2.cuda_GpuMat()
    g.upload(img)
    gray = cv2.cuda.cvtColor(g, cv2.COLOR_BGR2GRAY).download()
    ref = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    d1 = int(np.abs(gray.astype(int) - ref.astype(int)).max())
    small = cv2.cuda.resize(g, (640, 360), interpolation=cv2.INTER_LINEAR).download()
    assert small.shape == (360, 640, 3), "unexpected shape %s" % (small.shape,)
    assert d1 <= 1, "cvtColor differs by %d" % d1
    return "cvtColor difference %d, resize ok" % d1


@test
def opencv_dnn_cuda_matches_pytorch():
    cv2 = need("cv2")
    np = need("numpy")
    if cv2.cuda.getCudaEnabledDeviceCount() < 1:
        raise Skip("OpenCV has no CUDA support")
    path, x, ref = export_onnx()
    out = {}
    for name, target in (("fp32", cv2.dnn.DNN_TARGET_CUDA), ("fp16", cv2.dnn.DNN_TARGET_CUDA_FP16)):
        net = cv2.dnn.readNetFromONNX(path)
        net.setPreferableBackend(cv2.dnn.DNN_BACKEND_CUDA)
        net.setPreferableTarget(target)
        net.setInput(x.numpy())
        out[name] = float(np.abs(net.forward() - ref.numpy()).max())
    assert out["fp32"] < 1e-3 and out["fp16"] < 5e-2, "errors %s" % out
    return "max abs error FP32 %.1e, FP16 %.1e" % (out["fp32"], out["fp16"])


# --------------------------------------------------------------------------- VPI

def _vpi_box(backend_name):
    vpi = need("vpi")
    np = need("numpy")
    rng = np.random.RandomState(0)
    img = (rng.rand(480, 640) * 255).astype(np.uint8)
    with vpi.Backend.CPU:
        ref_img = vpi.asimage(img).box_filter(5, border=vpi.Border.ZERO)
    with ref_img.rlock_cpu() as d:
        ref = d.astype(int).copy()
    with getattr(vpi.Backend, backend_name):
        out_img = vpi.asimage(img).box_filter(5, border=vpi.Border.ZERO)
    with out_img.rlock_cpu() as d:
        out = d.astype(int).copy()
    inner = np.abs(out[8:-8, 8:-8] - ref[8:-8, 8:-8])
    return vpi.__version__, int(inner.max()), float(np.abs(out - ref).mean())


@test
def vpi_cuda_matches_cpu():
    ver, inner_max, mean_diff = _vpi_box("CUDA")
    assert inner_max <= 1, "interior differs by up to %d grey levels" % inner_max
    return "VPI %s, interior max difference %d" % (ver, inner_max)


@test
def vpi_pva_runs():
    """The PVA rounds differently from CPU/CUDA, so this allows a wider tolerance."""
    ver, inner_max, mean_diff = _vpi_box("PVA")
    assert mean_diff < 8, "mean difference %.1f grey levels" % mean_diff
    return "ran on PVA, mean difference vs CPU %.1f grey levels (interior max %d)" % (mean_diff, inner_max)


# --------------------------------------------------------------------------- runner

def main():
    words = [w.lower() for w in sys.argv[1:]]
    failed = 0
    for fn in TESTS:
        if words and not any(fn.__name__.startswith(w) for w in words):
            continue
        t0 = time.time()
        try:
            detail = fn() or ""
            status = "PASS"
        except Skip as e:
            status, detail = "SKIP", str(e)
        except Exception as e:
            status = "FAIL"
            detail = "%s: %s" % (type(e).__name__, str(e).splitlines()[0][:160] if str(e) else "")
            if os.environ.get("VERBOSE"):
                traceback.print_exc()
            failed += 1
        print("%-4s  %-38s %s  [%.1fs]" % (status, fn.__name__, detail, time.time() - t0), flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
