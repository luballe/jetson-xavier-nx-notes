/* CPU: all cores usable through OpenMP, and NEON SIMD gives the same answer as scalar code. */
#include <arm_neon.h>
#include <math.h>
#include <omp.h>
#include <stdlib.h>
#include <unistd.h>
#include "report.h"

int main(void) {
    /* 1. Every online core actually runs a thread. */
    long online = sysconf(_SC_NPROCESSORS_ONLN);
    int seen[64] = {0}, distinct = 0;
    #pragma omp parallel num_threads((int)online)
    {
        #pragma omp critical
        seen[omp_get_thread_num() % 64] = 1;
    }
    for (int i = 0; i < 64; i++) distinct += seen[i];
    if (distinct == online) report("PASS", "cpu_openmp_threads", "%d threads on %ld online cores", distinct, online);
    else report("FAIL", "cpu_openmp_threads", "%d threads started, %ld cores online", distinct, online);

    /* 2. Parallel reduction matches the closed form: sum of i for i < n. */
    const long n = 200000000L;
    double sum = 0.0, t0 = omp_get_wtime();
    #pragma omp parallel for reduction(+:sum)
    for (long i = 0; i < n; i++) sum += (double)i;
    double par = omp_get_wtime() - t0;
    double expect = (double)(n - 1) * (double)n / 2.0;
    if (fabs(sum - expect) / expect < 1e-12) report("PASS", "cpu_openmp_reduction", "correct, %.2f s with %ld threads", par, online);
    else report("FAIL", "cpu_openmp_reduction", "got %.0f expected %.0f", sum, expect);

    /* 3. NEON dot product equals the scalar one. */
    const int m = 1 << 20;
    float *a = malloc(m * sizeof *a), *b = malloc(m * sizeof *b);
    for (int i = 0; i < m; i++) { a[i] = (float)(i % 7) * 0.5f; b[i] = (float)(i % 5) * 0.25f; }
    double scalar = 0.0;
    for (int i = 0; i < m; i++) scalar += (double)a[i] * b[i];
    float64x2_t acc = vdupq_n_f64(0.0);
    for (int i = 0; i < m; i += 4) {
        float32x4_t p = vmulq_f32(vld1q_f32(a + i), vld1q_f32(b + i));
        acc = vaddq_f64(acc, vcvt_f64_f32(vget_low_f32(p)));
        acc = vaddq_f64(acc, vcvt_high_f64_f32(p));
    }
    double neon = vgetq_lane_f64(acc, 0) + vgetq_lane_f64(acc, 1);
    if (fabs(neon - scalar) / scalar < 1e-9) report("PASS", "cpu_neon_simd", "dot product matches scalar (%.1f)", neon);
    else report("FAIL", "cpu_neon_simd", "neon %.3f scalar %.3f", neon, scalar);
    free(a); free(b);
    return g_failed;
}
