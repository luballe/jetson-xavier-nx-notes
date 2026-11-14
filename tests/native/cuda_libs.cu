/* CUDA math libraries: cuBLAS (matrix product), cuFFT (round trip) and cuRAND (statistics). */
#include <cmath>
#include <vector>
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <cufft.h>
#include <curand.h>
#include "report.h"

int main() {
    /* cuBLAS: C = A*B against a plain CPU triple loop. Column-major, n x n. */
    const int n = 256;
    std::vector<float> A(n * n), B(n * n), C(n * n), R(n * n, 0.0f);
    for (int i = 0; i < n * n; i++) { A[i] = (float)((i * 7) % 13) / 13.0f; B[i] = (float)((i * 5) % 11) / 11.0f; }
    for (int j = 0; j < n; j++) for (int k = 0; k < n; k++) { float b = B[k + j * n]; for (int i = 0; i < n; i++) R[i + j * n] += A[i + k * n] * b; }
    float *dA, *dB, *dC;
    cudaMalloc(&dA, n * n * sizeof(float)); cudaMalloc(&dB, n * n * sizeof(float)); cudaMalloc(&dC, n * n * sizeof(float));
    cublasHandle_t h;
    if (cublasCreate(&h) != CUBLAS_STATUS_SUCCESS) { report("FAIL", "cublas_sgemm", "cublasCreate failed"); }
    else {
        cudaMemcpy(dA, A.data(), n * n * sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy(dB, B.data(), n * n * sizeof(float), cudaMemcpyHostToDevice);
        const float one = 1.0f, zero = 0.0f;
        cublasStatus_t s = cublasSgemm(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &one, dA, n, dB, n, &zero, dC, n);
        cudaMemcpy(C.data(), dC, n * n * sizeof(float), cudaMemcpyDeviceToHost);
        float err = 0.0f, mx = 0.0f;
        for (int i = 0; i < n * n; i++) { err = fmaxf(err, fabsf(C[i] - R[i])); mx = fmaxf(mx, fabsf(R[i])); }
        if (s == CUBLAS_STATUS_SUCCESS && err / mx < 1e-4f) report("PASS", "cublas_sgemm", "%dx%d product, relative error %.1e", n, n, err / mx);
        else report("FAIL", "cublas_sgemm", "status %d, relative error %.2e", (int)s, err / mx);
        cublasDestroy(h);
    }
    cudaFree(dA); cudaFree(dB); cudaFree(dC);

    /* cuFFT: forward then inverse must return the input (times N). */
    const int N = 1 << 16;
    std::vector<cufftComplex> sig(N), back(N);
    for (int i = 0; i < N; i++) { sig[i].x = sinf(0.01f * i) + 0.5f * cosf(0.37f * i); sig[i].y = 0.0f; }
    cufftComplex *d;
    cudaMalloc(&d, N * sizeof(cufftComplex));
    cudaMemcpy(d, sig.data(), N * sizeof(cufftComplex), cudaMemcpyHostToDevice);
    cufftHandle plan;
    if (cufftPlan1d(&plan, N, CUFFT_C2C, 1) != CUFFT_SUCCESS) { report("FAIL", "cufft_roundtrip", "cufftPlan1d failed"); }
    else {
        cufftResult r1 = cufftExecC2C(plan, d, d, CUFFT_FORWARD);
        cufftResult r2 = cufftExecC2C(plan, d, d, CUFFT_INVERSE);
        cudaMemcpy(back.data(), d, N * sizeof(cufftComplex), cudaMemcpyDeviceToHost);
        float err = 0.0f;
        for (int i = 0; i < N; i++) err = fmaxf(err, fabsf(back[i].x / N - sig[i].x));
        if (r1 == CUFFT_SUCCESS && r2 == CUFFT_SUCCESS && err < 1e-3f) report("PASS", "cufft_roundtrip", "%d-point FFT and inverse, max error %.1e", N, err);
        else report("FAIL", "cufft_roundtrip", "max error %.2e", err);
        cufftDestroy(plan);
    }
    cudaFree(d);

    /* cuRAND: a million uniform samples should average 0.5. */
    const int M = 1 << 20;
    float *dr; std::vector<float> hr(M);
    cudaMalloc(&dr, M * sizeof(float));
    curandGenerator_t g;
    if (curandCreateGenerator(&g, CURAND_RNG_PSEUDO_DEFAULT) != CURAND_STATUS_SUCCESS) { report("FAIL", "curand_uniform", "generator creation failed"); }
    else {
        curandSetPseudoRandomGeneratorSeed(g, 1234ULL);
        curandGenerateUniform(g, dr, M);
        cudaMemcpy(hr.data(), dr, M * sizeof(float), cudaMemcpyDeviceToHost);
        double mean = 0.0; for (int i = 0; i < M; i++) mean += hr[i]; mean /= M;
        if (fabs(mean - 0.5) < 0.005) report("PASS", "curand_uniform", "mean of %d samples %.4f", M, mean);
        else report("FAIL", "curand_uniform", "mean %.4f, expected about 0.5", mean);
        curandDestroyGenerator(g);
    }
    cudaFree(dr);
    return g_failed;
}
