#!/bin/bash
# CUDA, cuDNN, TensorRT and VPI from NVIDIA's apt repository, including the
# development packages (compiler, headers, Python bindings). Run as root.
# OpenCV is not installed here: see build_opencv_cuda.sh.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get -y -q install nvidia-cuda nvidia-cudnn8 nvidia-tensorrt \
    nvidia-cuda-dev nvidia-cudnn8-dev nvidia-tensorrt-dev
# VPI without the metapackage, which would pull in Python 3.9.
apt-get -y -q install libnvvpi2 python3.8-vpi2 vpi2-dev vpi2-samples
echo 'Add to ~/.bashrc:  export PATH=/usr/local/cuda/bin:$PATH'
echo '                   export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH'
