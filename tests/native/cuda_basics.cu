/* CUDA: device properties, a kernel on unified memory, and zero-copy access to
 * pinned host memory (the pattern that avoids CPU<->GPU copies on a Jetson). */
#include <cuda_runtime.h>
#include "report.h"

__global__ void saxpy(int n, float a, const float *x, float *y) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) y[i] = a * x[i] + y[i];
}
__global__ void scale(int n, float a, float *x) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) x[i] *= a;
}

int main() {
    cudaDeviceProp p;
    if (cudaGetDeviceProperties(&p, 0) != cudaSuccess) { report("FAIL", "cuda_device", "no CUDA device"); return 1; }
    size_t freeb = 0, total = 0;
    cudaMemGetInfo(&freeb, &total);
    report("PASS", "cuda_device", "%s, compute capability %d.%d, %zu MiB free of %zu, integrated=%d",
           p.name, p.major, p.minor, freeb >> 20, total >> 20, p.integrated);

    const int n = 1 << 22;
    /* Unified memory: one pointer valid on both sides. */
    float *x, *y;
    if (cudaMallocManaged(&x, n * sizeof(float)) != cudaSuccess || cudaMallocManaged(&y, n * sizeof(float)) != cudaSuccess) {
        report("FAIL", "cuda_unified_memory", "cudaMallocManaged failed"); return 1;
    }
    for (int i = 0; i < n; i++) { x[i] = 1.0f; y[i] = 2.0f; }
    saxpy<<<(n + 255) / 256, 256>>>(n, 3.0f, x, y);
    cudaError_t e = cudaDeviceSynchronize();
    int bad = 0;
    for (int i = 0; i < n; i++) if (y[i] != 5.0f) bad++;
    if (e == cudaSuccess && bad == 0) report("PASS", "cuda_unified_memory", "saxpy over %d elements correct", n);
    else report("FAIL", "cuda_unified_memory", "%d wrong elements, %s", bad, cudaGetErrorString(e));
    cudaFree(x); cudaFree(y);

    /* Zero-copy: the GPU works directly on a pinned host buffer, no memcpy either way. */
    cudaSetDeviceFlags(cudaDeviceMapHost);
    float *host = NULL, *dev = NULL;
    e = cudaHostAlloc((void **)&host, n * sizeof(float), cudaHostAllocMapped);
    if (e == cudaSuccess) e = cudaHostGetDevicePointer((void **)&dev, host, 0);
    if (e != cudaSuccess) {
        report("FAIL", "cuda_zero_copy_pinned", "%s", cudaGetErrorString(e));
    } else {
        for (int i = 0; i < n; i++) host[i] = (float)(i & 1023);
        scale<<<(n + 255) / 256, 256>>>(n, 2.0f, dev);
        e = cudaDeviceSynchronize();
        bad = 0;
        for (int i = 0; i < n; i++) if (host[i] != 2.0f * (float)(i & 1023)) bad++;
        if (e == cudaSuccess && bad == 0) report("PASS", "cuda_zero_copy_pinned", "GPU modified host buffer in place, 0 wrong of %d", n);
        else report("FAIL", "cuda_zero_copy_pinned", "%d wrong elements, %s", bad, cudaGetErrorString(e));
        cudaFreeHost(host);
    }
    return g_failed;
}
