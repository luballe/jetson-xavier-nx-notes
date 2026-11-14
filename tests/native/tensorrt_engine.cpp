/* TensorRT from C++: define a one-convolution network with the builder API, build an
 * engine for the GPU and for each DLA core, run it and check the numbers.
 * The convolution is a 3x3 box sum over an all-ones 3-channel image, so every interior
 * output must be 27. */
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include <cuda_runtime.h>
#include <NvInfer.h>
#include "report.h"

using namespace nvinfer1;

class Logger : public ILogger {
    void log(Severity s, const char *msg) noexcept override {
        if (s <= Severity::kERROR && !getenv("QUIET_TRT")) fprintf(stderr, "[TRT] %s\n", msg);
    }
} gLogger;

template <typename T> using uptr = std::unique_ptr<T>;

/* dla < 0 means GPU. Returns 0 pass, 1 fail, 2 skip. */
static int run(const char *name, int dla) {
    const int C = 3, H = 32, W = 32, K = 4;
    uptr<IBuilder> builder(createInferBuilder(gLogger));
    if (!builder) { report("FAIL", name, "createInferBuilder failed"); return 1; }
    if (dla >= builder->getNbDLACores()) { report("SKIP", name, "module reports %d DLA cores", builder->getNbDLACores()); return 2; }
    uptr<INetworkDefinition> net(builder->createNetworkV2(1U << static_cast<int>(NetworkDefinitionCreationFlag::kEXPLICIT_BATCH)));
    ITensor *in = net->addInput("input", DataType::kFLOAT, Dims4{1, C, H, W});
    std::vector<float> w(K * C * 3 * 3, 1.0f), b(K, 0.0f);
    IConvolutionLayer *conv = net->addConvolutionNd(*in, K, Dims2{3, 3},
        Weights{DataType::kFLOAT, w.data(), (int64_t)w.size()}, Weights{DataType::kFLOAT, b.data(), (int64_t)b.size()});
    conv->setPaddingNd(Dims2{1, 1});
    conv->getOutput(0)->setName("output");
    net->markOutput(*conv->getOutput(0));

    uptr<IBuilderConfig> cfg(builder->createBuilderConfig());
    cfg->setMemoryPoolLimit(MemoryPoolType::kWORKSPACE, 128ULL << 20);
    cfg->setProfilingVerbosity(ProfilingVerbosity::kDETAILED);
    if (dla >= 0) {
        cfg->setFlag(BuilderFlag::kFP16);            /* DLA runs FP16 or INT8 only */
        cfg->setFlag(BuilderFlag::kGPU_FALLBACK);
        cfg->setDefaultDeviceType(DeviceType::kDLA);
        cfg->setDLACore(dla);
    }
    uptr<IHostMemory> plan(builder->buildSerializedNetwork(*net, *cfg));
    if (!plan) { report("FAIL", name, "engine build failed"); return 1; }
    uptr<IRuntime> runtime(createInferRuntime(gLogger));
    if (dla >= 0) runtime->setDLACore(dla);
    uptr<ICudaEngine> engine(runtime->deserializeCudaEngine(plan->data(), plan->size()));
    if (!engine) { report("FAIL", name, "deserialize failed"); return 1; }
    uptr<IEngineInspector> insp(engine->createEngineInspector());
    std::string info = insp->getEngineInformation(LayerInformationFormat::kONELINE);
    bool onDla = info.find("ForeignNode") != std::string::npos;
    uptr<IExecutionContext> ctx(engine->createExecutionContext());

    std::vector<float> hin(C * H * W, 1.0f), hout(K * H * W, 0.0f);
    float *din, *dout;
    cudaMalloc(&din, hin.size() * sizeof(float)); cudaMalloc(&dout, hout.size() * sizeof(float));
    cudaMemcpy(din, hin.data(), hin.size() * sizeof(float), cudaMemcpyHostToDevice);
    void *bind[2];
    bind[engine->getBindingIndex("input")] = din;
    bind[engine->getBindingIndex("output")] = dout;
    bool ok = ctx->executeV2(bind);
    cudaMemcpy(hout.data(), dout, hout.size() * sizeof(float), cudaMemcpyDeviceToHost);
    cudaFree(din); cudaFree(dout);

    int bad = 0;
    for (int k = 0; k < K; k++) for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        int ny = (y == 0 || y == H - 1) ? 2 : 3, nx = (x == 0 || x == W - 1) ? 2 : 3;
        if (std::fabs(hout[(k * H + y) * W + x] - (float)(C * ny * nx)) > 0.05f) bad++;
    }
    if (!ok || bad) { report("FAIL", name, "executeV2=%d, %d wrong outputs", (int)ok, bad); return 1; }
    if (dla >= 0 && !onDla) { report("FAIL", name, "correct, but the layer fell back to the GPU instead of DLA %d", dla); return 1; }
    report("PASS", name, "TensorRT %d.%d.%d, %d outputs correct%s", NV_TENSORRT_MAJOR, NV_TENSORRT_MINOR, NV_TENSORRT_PATCH,
           K * H * W, dla >= 0 ? ", layer placed on the DLA" : "");
    return 0;
}

int main() {
    run("tensorrt_cpp_gpu", -1);
    run("tensorrt_cpp_dla0", 0);
    run("tensorrt_cpp_dla1", 1);
    return g_failed;
}
