#!/bin/bash
# NVIDIA's PyTorch 2.1 build for JetPack 5 (Python 3.8, CUDA 11.4). Run as root.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get -y -q install python3-pip libopenblas-dev libopenmpi-dev libomp-dev wget
python3 -m pip install --upgrade pip
python3 -m pip install "numpy==1.24.4"
W=torch-2.1.0a0+41361538.nv23.06-cp38-cp38-linux_aarch64.whl
cd /tmp && wget -q "https://developer.download.nvidia.com/compute/redist/jp/v512/pytorch/$W"
python3 -m pip install "/tmp/$W"
rm -f "/tmp/$W"
python3 -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
