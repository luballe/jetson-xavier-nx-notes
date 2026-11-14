# Builds the native tests. Each binary is independent: a missing library only
# skips that one test (run_all.sh reports it), it does not stop the others.
#   make            build everything that can be built
#   make clean
CUDA    ?= /usr/local/cuda
NVCC    ?= $(CUDA)/bin/nvcc
CXX     ?= g++
CC      ?= gcc
CFLAGS  += -O2 -Wall
CUDAINC := -I$(CUDA)/include
CUDALIB := -L$(CUDA)/lib64 -lcudart
OPENCV  := $(shell pkg-config --cflags --libs opencv4 2>/dev/null)
OPENCV_HAS_CUDA := $(shell pkg-config --libs opencv4 2>/dev/null | grep -q cudafilters && echo -DHAVE_OPENCV_CUDAFILTERS)

BINS := cpu_openmp_neon cuda_basics cuda_libs cudnn_conv tensorrt_engine opencv_cuda vpi_backends

all:
	@for b in $(BINS); do $(MAKE) -s $$b 2>build_$$b.log && rm -f build_$$b.log || echo "build failed: $$b (see tests/native/build_$$b.log)"; done

cpu_openmp_neon: cpu_openmp_neon.c report.h
	$(CC) $(CFLAGS) -fopenmp $< -o $@ -lm

cuda_basics: cuda_basics.cu report.h
	$(NVCC) -O2 $< -o $@

cuda_libs: cuda_libs.cu report.h
	$(NVCC) -O2 $< -o $@ -lcublas -lcufft -lcurand

cudnn_conv: cudnn_conv.cpp report.h
	$(CXX) $(CFLAGS) $(CUDAINC) $< -o $@ $(CUDALIB) -lcudnn

tensorrt_engine: tensorrt_engine.cpp report.h
	$(CXX) $(CFLAGS) -Wno-deprecated-declarations $(CUDAINC) $< -o $@ $(CUDALIB) -lnvinfer

opencv_cuda: opencv_cuda.cpp report.h
	$(CXX) $(CFLAGS) $(OPENCV_HAS_CUDA) $< -o $@ $(OPENCV)

vpi_backends: vpi_backends.c report.h
	$(CC) $(CFLAGS) $< -o $@ -lnvvpi

clean:
	rm -f $(BINS) build_*.log

.PHONY: all clean
