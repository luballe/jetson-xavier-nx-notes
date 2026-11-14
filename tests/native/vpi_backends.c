/* VPI from C: the same box filter on CPU, CUDA and PVA backends, compared with the CPU result. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <vpi/Image.h>
#include <vpi/Status.h>
#include <vpi/Stream.h>
#include <vpi/algo/BoxFilter.h>
#include "report.h"

#define W 640
#define H 480

static int run(uint64_t backend, const uint8_t *src, uint8_t *dst, char *err, size_t errlen) {
    VPIStream stream = NULL; VPIImage in = NULL, out = NULL; VPIImageData d; int rc = 1;
    VPIStatus s = vpiStreamCreate(backend, &stream);
    if (s == VPI_SUCCESS) s = vpiImageCreate(W, H, VPI_IMAGE_FORMAT_U8, 0, &in);
    if (s == VPI_SUCCESS) s = vpiImageCreate(W, H, VPI_IMAGE_FORMAT_U8, 0, &out);
    if (s == VPI_SUCCESS) s = vpiImageLockData(in, VPI_LOCK_WRITE, VPI_IMAGE_BUFFER_HOST_PITCH_LINEAR, &d);
    if (s == VPI_SUCCESS) {
        for (int y = 0; y < H; y++)
            memcpy((uint8_t *)d.buffer.pitch.planes[0].data + (size_t)y * d.buffer.pitch.planes[0].pitchBytes, src + (size_t)y * W, W);
        vpiImageUnlock(in);
        s = vpiSubmitBoxFilter(stream, backend, in, out, 5, 5, VPI_BORDER_ZERO);
    }
    if (s == VPI_SUCCESS) s = vpiStreamSync(stream);
    if (s == VPI_SUCCESS) s = vpiImageLockData(out, VPI_LOCK_READ, VPI_IMAGE_BUFFER_HOST_PITCH_LINEAR, &d);
    if (s == VPI_SUCCESS) {
        for (int y = 0; y < H; y++)
            memcpy(dst + (size_t)y * W, (uint8_t *)d.buffer.pitch.planes[0].data + (size_t)y * d.buffer.pitch.planes[0].pitchBytes, W);
        vpiImageUnlock(out);
        rc = 0;
    } else {
        char msg[VPI_MAX_STATUS_MESSAGE_LENGTH];
        vpiGetLastStatusMessage(msg, sizeof msg);
        snprintf(err, errlen, "%s: %s", vpiStatusGetName(s), msg);
    }
    vpiStreamDestroy(stream); vpiImageDestroy(in); vpiImageDestroy(out);
    return rc;
}

int main(void) {
    static uint8_t src[W * H], cpu[W * H], other[W * H];
    char err[512];
    srand(1);
    for (int i = 0; i < W * H; i++) src[i] = (uint8_t)(rand() & 0xff);

    if (run(VPI_BACKEND_CPU, src, cpu, err, sizeof err)) { report("FAIL", "vpi_c_cpu", "%s", err); return 1; }
    report("PASS", "vpi_c_cpu", "5x5 box filter on %dx%d", W, H);

    const struct { uint64_t b; const char *name; int tol; } t[] = {
        {VPI_BACKEND_CUDA, "vpi_c_cuda", 1},
        {VPI_BACKEND_PVA, "vpi_c_pva", 8},   /* the PVA rounds differently: allow a wider margin */
    };
    for (int k = 0; k < 2; k++) {
        if (run(t[k].b, src, other, err, sizeof err)) { report("FAIL", t[k].name, "%s", err); continue; }
        int mx = 0; double mean = 0;
        for (int y = 8; y < H - 8; y++) for (int x = 8; x < W - 8; x++) {
            int dd = abs((int)other[y * W + x] - (int)cpu[y * W + x]);
            if (dd > mx) mx = dd;
            mean += dd;
        }
        mean /= (double)(W - 16) * (H - 16);
        if (mx <= t[k].tol) report("PASS", t[k].name, "max difference vs CPU %d grey level(s), mean %.2f", mx, mean);
        else report("FAIL", t[k].name, "max difference vs CPU %d grey levels (allowed %d)", mx, t[k].tol);
    }
    return g_failed;
}
