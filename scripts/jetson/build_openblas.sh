#!/bin/bash
# Build OpenBLAS 0.3.28 with OpenMP and make it the system BLAS and LAPACK.
# Needed because Ubuntu 20.04's OpenBLAS 0.3.8 does not recognise the Carmel CPU and
# returns NaN from matrix products (see docs/07-pytorch-openblas-nan.md).
# About 15 minutes. Run as root.
# Undo with: update-alternatives --auto <name>-aarch64-linux-gnu   for each name below.
set -e
V=0.3.28; B=${BUILD_DIR:-$HOME/openblas_build}
OPTS="USE_OPENMP=1 TARGET=ARMV8 NUM_THREADS=16"
O=/opt/OpenBLAS; L=/usr/lib/aarch64-linux-gnu; I=/usr/include/aarch64-linux-gnu; T=aarch64-linux-gnu

apt-get -y -q install build-essential gfortran wget
if [ ! -f $O/lib/libopenblas.so.0 ]; then
  mkdir -p "$B"; cd "$B"
  [ -d OpenBLAS-$V ] || { wget -q -O ob.tgz https://github.com/OpenMathLib/OpenBLAS/archive/refs/tags/v$V.tar.gz; tar xf ob.tgz; rm ob.tgz; }
  cd OpenBLAS-$V
  make -j"$(nproc)" $OPTS
  make install PREFIX=$O $OPTS
fi

# pkg-config files for the generic names "blas" and "lapack"
for n in blas lapack; do
cat > $O/lib/pkgconfig/$n-openblas.pc <<P
Name: openblas-$n
Description: OpenBLAS $V in $O, used as $n
Version: $V
URL: https://github.com/OpenMathLib/OpenBLAS
Libs: -L$O/lib -lopenblas
Cflags: -I$O/include
P
done

# Run time: what PyTorch (libopenblas.so.0), OpenCV (liblapack.so.3) and -lblas programs load
for n in libopenblas.so.0 libblas.so.3 liblapack.so.3; do
  update-alternatives --install $L/$n $n-$T $O/lib/libopenblas.so.0 200
  update-alternatives --set $n-$T $O/lib/libopenblas.so.0
done

# Build time: what -lblas, -llapack, -lopenblas, pkg-config and <cblas.h> resolve to
update-alternatives --install $L/libblas.so libblas.so-$T $O/lib/libopenblas.so 200 \
  --slave $L/pkgconfig/blas.pc blas.pc-$T $O/lib/pkgconfig/blas-openblas.pc \
  --slave $I/cblas.h cblas.h-$T $O/include/cblas.h \
  --slave $L/libblas.a libblas.a-$T $O/lib/libopenblas.a
update-alternatives --set libblas.so-$T $O/lib/libopenblas.so
update-alternatives --install $L/liblapack.so liblapack.so-$T $O/lib/libopenblas.so 200 \
  --slave $L/pkgconfig/lapack.pc lapack.pc-$T $O/lib/pkgconfig/lapack-openblas.pc \
  --slave $L/liblapack.a liblapack.a-$T $O/lib/libopenblas.a
update-alternatives --set liblapack.so-$T $O/lib/libopenblas.so
update-alternatives --install $L/libopenblas.so libopenblas.so-$T $O/lib/libopenblas.so 200 \
  --slave $I/cblas-openblas.h cblas-openblas.h-$T $O/include/cblas.h \
  --slave $I/f77blas.h f77blas.h-$T $O/include/f77blas.h \
  --slave $L/libopenblas.a libopenblas.a-$T $O/lib/libopenblas.a \
  --slave $L/pkgconfig/openblas.pc openblas.pc-$T $O/lib/pkgconfig/openblas.pc \
  --slave $I/openblas_config.h openblas_config.h-$T $O/include/openblas_config.h
update-alternatives --set libopenblas.so-$T $O/lib/libopenblas.so
ldconfig
update-alternatives --get-selections | grep -i -E "blas|lapack"
