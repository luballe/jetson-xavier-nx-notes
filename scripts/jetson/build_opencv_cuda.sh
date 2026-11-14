#!/bin/bash
# Build OpenCV 4.10.0 with CUDA, cuDNN and the contrib modules for Xavier NX.
# Run as root. Took 2 h 05 min with 6 cores (nvpmodel mode 8). Install NumPy first.
# This script only compiles. To install afterwards:
#   cd $B/opencv-$V/build && make install && ldconfig
#   echo /usr/local/lib/python3.8/site-packages > /usr/local/lib/python3.8/dist-packages/opencv-local.pth
#   apt remove libopencv libopencv-dev libopencv-python libopencv-samples opencv-licenses nvidia-opencv nvidia-opencv-dev
set -e
V=4.10.0; B=${BUILD_DIR:-$HOME/opencv_build}
export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/cuda/bin:$PATH
echo no | nvpmodel -m 8 || true          # 20 W, 6 cores; answers "no" to a reboot prompt
# Optional safety net for memory; it was not needed (peak about 3.3 GB).
if [ ! -f /swapfile_build ]; then fallocate -l 8G /swapfile_build; chmod 600 /swapfile_build; mkswap /swapfile_build; fi
swapon /swapfile_build || true
apt-get -y -q install build-essential cmake git pkg-config unzip wget libgtk-3-dev \
  libavcodec-dev libavformat-dev libswscale-dev libavutil-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libjpeg-dev libpng-dev libtiff-dev libwebp-dev \
  libv4l-dev v4l-utils libeigen3-dev libtbb-dev libopenblas-dev liblapack-dev liblapacke-dev \
  libatlas-base-dev gfortran python3-dev libxvidcore-dev libx264-dev
mkdir -p "$B"; cd "$B"
[ -d opencv-$V ] || { wget -q -O o.zip https://github.com/opencv/opencv/archive/refs/tags/$V.zip; unzip -q o.zip; rm o.zip; }
[ -d opencv_contrib-$V ] || { wget -q -O c.zip https://github.com/opencv/opencv_contrib/archive/refs/tags/$V.zip; unzip -q c.zip; rm c.zip; }
mkdir -p opencv-$V/build; cd opencv-$V/build
cmake -D CMAKE_BUILD_TYPE=RELEASE -D CMAKE_INSTALL_PREFIX=/usr/local \
  -D OPENCV_EXTRA_MODULES_PATH=$B/opencv_contrib-$V/modules \
  -D WITH_CUDA=ON -D WITH_CUDNN=ON -D OPENCV_DNN_CUDA=ON -D CUDA_ARCH_BIN=7.2 -D CUDA_ARCH_PTX="" \
  -D ENABLE_FAST_MATH=ON -D CUDA_FAST_MATH=ON -D WITH_CUBLAS=ON -D ENABLE_NEON=ON \
  -D WITH_GSTREAMER=ON -D WITH_LIBV4L=ON -D WITH_V4L=ON -D WITH_FFMPEG=ON -D WITH_TBB=ON -D WITH_EIGEN=ON \
  -D EIGEN_INCLUDE_PATH=/usr/include/eigen3 -D WITH_OPENGL=OFF -D WITH_QT=OFF \
  -D BUILD_opencv_python3=ON -D BUILD_opencv_python2=OFF -D PYTHON3_EXECUTABLE=/usr/bin/python3 \
  -D OPENCV_GENERATE_PKGCONFIG=ON -D OPENCV_ENABLE_NONFREE=ON \
  -D BUILD_TESTS=OFF -D BUILD_PERF_TESTS=OFF -D BUILD_EXAMPLES=OFF -D INSTALL_PYTHON_EXAMPLES=OFF -D INSTALL_C_EXAMPLES=OFF ..
make -j$(nproc)
echo "Compiled. Remove the temporary swap with: swapoff /swapfile_build && rm /swapfile_build"
