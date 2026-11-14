/* cuDNN from C++: a 3x3 all-ones convolution over an all-ones image.
 * With padding 1 every interior output must be exactly 9 and every corner 4. */
#include <vector>
#include <cuda_runtime.h>
#include <cudnn.h>
#include "report.h"

#define CHECK(call) do { cudnnStatus_t s_ = (call); if (s_ != CUDNN_STATUS_SUCCESS) { \
    report("FAIL", "cudnn_convolution", "%s -> %s", #call, cudnnGetErrorString(s_)); return 1; } } while (0)

int main() {
    const int H = 64, W = 64;
    cudnnHandle_t h; CHECK(cudnnCreate(&h));
    cudnnTensorDescriptor_t in, out; cudnnFilterDescriptor_t filt; cudnnConvolutionDescriptor_t conv;
    CHECK(cudnnCreateTensorDescriptor(&in)); CHECK(cudnnCreateTensorDescriptor(&out));
    CHECK(cudnnCreateFilterDescriptor(&filt)); CHECK(cudnnCreateConvolutionDescriptor(&conv));
    CHECK(cudnnSetTensor4dDescriptor(in, CUDNN_TENSOR_NCHW, CUDNN_DATA_FLOAT, 1, 1, H, W));
    CHECK(cudnnSetFilter4dDescriptor(filt, CUDNN_DATA_FLOAT, CUDNN_TENSOR_NCHW, 1, 1, 3, 3));
    CHECK(cudnnSetConvolution2dDescriptor(conv, 1, 1, 1, 1, 1, 1, CUDNN_CROSS_CORRELATION, CUDNN_DATA_FLOAT));
    int n, c, oh, ow;
    CHECK(cudnnGetConvolution2dForwardOutputDim(conv, in, filt, &n, &c, &oh, &ow));
    CHECK(cudnnSetTensor4dDescriptor(out, CUDNN_TENSOR_NCHW, CUDNN_DATA_FLOAT, n, c, oh, ow));

    std::vector<float> hx(H * W, 1.0f), hw(9, 1.0f), hy(oh * ow, 0.0f);
    float *dx, *dw, *dy;
    cudaMalloc(&dx, hx.size() * sizeof(float)); cudaMalloc(&dw, hw.size() * sizeof(float)); cudaMalloc(&dy, hy.size() * sizeof(float));
    cudaMemcpy(dx, hx.data(), hx.size() * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(dw, hw.data(), hw.size() * sizeof(float), cudaMemcpyHostToDevice);

    cudnnConvolutionFwdAlgo_t algo = CUDNN_CONVOLUTION_FWD_ALGO_IMPLICIT_PRECOMP_GEMM;
    size_t ws = 0; CHECK(cudnnGetConvolutionForwardWorkspaceSize(h, in, filt, conv, out, algo, &ws));
    void *dws = NULL; if (ws) cudaMalloc(&dws, ws);
    const float alpha = 1.0f, beta = 0.0f;
    CHECK(cudnnConvolutionForward(h, &alpha, in, dx, filt, dw, conv, algo, dws, ws, &beta, out, dy));
    cudaMemcpy(hy.data(), dy, hy.size() * sizeof(float), cudaMemcpyDeviceToHost);

    int bad = 0;
    for (int y = 0; y < oh; y++) for (int x = 0; x < ow; x++) {
        int ny = (y == 0 || y == oh - 1) ? 2 : 3, nx = (x == 0 || x == ow - 1) ? 2 : 3;
        if (hy[y * ow + x] != (float)(ny * nx)) bad++;
    }
    if (oh == H && ow == W && bad == 0) report("PASS", "cudnn_convolution", "cuDNN %d.%d.%d, %dx%d output exact", CUDNN_MAJOR, CUDNN_MINOR, CUDNN_PATCHLEVEL, oh, ow);
    else report("FAIL", "cudnn_convolution", "%d wrong outputs (size %dx%d)", bad, oh, ow);

    cudaFree(dx); cudaFree(dw); cudaFree(dy); if (dws) cudaFree(dws);
    cudnnDestroyTensorDescriptor(in); cudnnDestroyTensorDescriptor(out);
    cudnnDestroyFilterDescriptor(filt); cudnnDestroyConvolutionDescriptor(conv); cudnnDestroy(h);
    return g_failed;
}
