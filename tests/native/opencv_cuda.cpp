/* OpenCV CUDA from C++: a GPU filter against the CPU one, and a zero-copy image shared
 * between cv::Mat and cv::cuda::GpuMat through HostMem::SHARED. */
#include <opencv2/core.hpp>
#include <opencv2/core/cuda.hpp>
#include <opencv2/imgproc.hpp>
#include "report.h"
#ifdef HAVE_OPENCV_CUDAFILTERS
#include <opencv2/cudaarithm.hpp>
#include <opencv2/cudafilters.hpp>
#endif

int main() {
    int n = cv::cuda::getCudaEnabledDeviceCount();
    if (n < 1) {
        report("FAIL", "opencv_cpp_cuda_devices", "OpenCV %s sees no CUDA device (built without CUDA?)", CV_VERSION);
        return 1;
    }
    report("PASS", "opencv_cpp_cuda_devices", "OpenCV %s, %d CUDA device", CV_VERSION, n);
#ifdef HAVE_OPENCV_CUDAFILTERS
    cv::Mat img(1080, 1920, CV_8UC1);
    cv::RNG rng(0);
    rng.fill(img, cv::RNG::UNIFORM, 0, 256);

    cv::cuda::GpuMat g(img), gout;
    cv::Ptr<cv::cuda::Filter> f = cv::cuda::createGaussianFilter(CV_8UC1, CV_8UC1, cv::Size(9, 9), 2);
    f->apply(g, gout);
    cv::Mat fromGpu, cpu, diff;
    gout.download(fromGpu);
    cv::GaussianBlur(img, cpu, cv::Size(9, 9), 2);
    cv::absdiff(fromGpu, cpu, diff);
    double mx; cv::minMaxLoc(diff, nullptr, &mx);
    if (mx <= 2) report("PASS", "opencv_cpp_cuda_filter", "1080p Gaussian, max difference %.0f grey level(s)", mx);
    else report("FAIL", "opencv_cpp_cuda_filter", "max difference %.0f grey levels", mx);

    /* Zero-copy: one buffer, seen as Mat by the CPU and as GpuMat by the GPU. */
    cv::cuda::HostMem shared(480, 640, CV_8UC1, cv::cuda::HostMem::SHARED);
    cv::Mat asMat = shared.createMatHeader();
    asMat.setTo(10);
    cv::cuda::GpuMat asGpu = shared.createGpuMatHeader();
    cv::cuda::add(asGpu, cv::Scalar(5), asGpu);          /* GPU writes into the shared buffer */
    cv::cuda::Stream::Null().waitForCompletion();
    int wrong = cv::countNonZero(asMat != 15);            /* CPU reads it, no download() */
    if (wrong == 0) report("PASS", "opencv_cpp_zero_copy", "GPU result visible to the CPU without a download");
    else report("FAIL", "opencv_cpp_zero_copy", "%d pixels differ", wrong);
#else
    report("SKIP", "opencv_cpp_cuda_filter", "cudafilters module not built");
#endif
    return g_failed;
}
