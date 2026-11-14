#!/bin/bash
# Build OpenBLAS 0.3.28 with OpenMP and make it the system libopenblas.so.0.
# Needed because Ubuntu 20.04's OpenBLAS 0.3.8 gives NaN from PyTorch on the CPU when
# multi-threaded (see docs/03-software-stack.md). About 15 minutes. Run as root.
# Undo with: update-alternatives --config libopenblas.so.0-aarch64-linux-gnu
set -e
V=0.3.28; B=${BUILD_DIR:-$HOME/openblas_build}
OPTS="USE_OPENMP=1 TARGET=ARMV8 NUM_THREADS=16"
apt-get -y -q install build-essential gfortran wget
mkdir -p "$B"; cd "$B"
[ -d OpenBLAS-$V ] || { wget -q -O ob.tgz https://github.com/OpenMathLib/OpenBLAS/archive/refs/tags/v$V.tar.gz; tar xf ob.tgz; rm ob.tgz; }
cd OpenBLAS-$V
make -j"$(nproc)" $OPTS
make install PREFIX=/opt/OpenBLAS $OPTS
A=libopenblas.so.0-aarch64-linux-gnu
update-alternatives --install /usr/lib/aarch64-linux-gnu/libopenblas.so.0 $A /opt/OpenBLAS/lib/libopenblas.so.0 200
update-alternatives --set $A /opt/OpenBLAS/lib/libopenblas.so.0
ldconfig
readlink -f /usr/lib/aarch64-linux-gnu/libopenblas.so.0
