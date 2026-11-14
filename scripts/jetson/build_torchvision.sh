#!/bin/bash
# Build torchvision 0.16.1, the version that pairs with PyTorch 2.1. Run as root.
set -e
export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/cuda/bin:$PATH BUILD_VERSION=0.16.1
apt-get -y -q install libjpeg-dev zlib1g-dev libpng-dev libpython3-dev \
    libavcodec-dev libavformat-dev libswscale-dev git
python3 -m pip install "pillow<11" requests
B=${BUILD_DIR:-$HOME/tv_build}
mkdir -p "$B"; cd "$B"
[ -d vision ] || git clone -q --depth 1 --branch v0.16.1 https://github.com/pytorch/vision
cd vision
python3 setup.py install
