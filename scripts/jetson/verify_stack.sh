#!/bin/bash
# Smoke-test the GPU stack: compile and run a CUDA kernel, then load cuDNN,
# TensorRT, PyTorch, OpenCV (CUDA) and VPI from Python.
export PATH=/usr/local/cuda/bin:$PATH
T=$(mktemp -d); cd "$T"
cat > t.cu <<'C'
#include <stdio.h>
#include <cuda_runtime.h>
__global__ void add(int n, float *x, float *y){ int i = blockIdx.x*blockDim.x+threadIdx.x; if(i<n) y[i]=x[i]+y[i]; }
int main(){ int n=1<<20; float *x,*y; cudaDeviceProp p; if(cudaGetDeviceProperties(&p,0)!=cudaSuccess){printf("NO GPU\n");return 1;}
 cudaMallocManaged(&x,n*sizeof(float)); cudaMallocManaged(&y,n*sizeof(float)); for(int i=0;i<n;i++){x[i]=1;y[i]=2;}
 add<<<(n+255)/256,256>>>(n,x,y); cudaDeviceSynchronize(); float e=0; for(int i=0;i<n;i++) if(y[i]!=3) e++;
 printf("CUDA kernel on %s, wrong elements: %.0f\n",p.name,e); return e!=0; }
C
nvcc t.cu -o t_cuda 2>/dev/null && ./t_cuda
python3 - <<'P'
import ctypes, numpy as np
c = ctypes.CDLL("libcudnn.so.8"); c.cudnnGetVersion.restype = ctypes.c_size_t
print("cuDNN", c.cudnnGetVersion())
import tensorrt as trt
print("TensorRT", trt.__version__, "fp16:", trt.Builder(trt.Logger(trt.Logger.ERROR)).platform_has_fast_fp16)
import torch
print("PyTorch", torch.__version__, "CUDA:", torch.cuda.is_available())
a = torch.rand(2000, 2000, device="cuda"); print("  GPU matmul ok:", (a @ a).sum().item() > 0)
import cv2
print("OpenCV", cv2.__version__, "CUDA devices:", cv2.cuda.getCudaEnabledDeviceCount())
g = cv2.cuda_GpuMat(); g.upload((np.random.rand(1080, 1920) * 255).astype(np.uint8))
f = cv2.cuda.createGaussianFilter(cv2.CV_8UC1, cv2.CV_8UC1, (9, 9), 2); print("  GPU filter ok:", f.apply(g).download().shape)
import vpi
img = (np.random.rand(480, 640) * 255).astype(np.uint8)
for b, n in ((vpi.Backend.CPU, "CPU"), (vpi.Backend.CUDA, "CUDA"), (vpi.Backend.PVA, "PVA")):
    with b: o = vpi.asimage(img).box_filter(5, border=vpi.Border.ZERO)
    with o.rlock_cpu() as d: print("VPI", n, "mean", round(float(d.mean()), 1))
try:
    import torchvision; print("torchvision", torchvision.__version__)
except Exception as e: print("torchvision not available:", e)
P
cd /; rm -rf "$T"
