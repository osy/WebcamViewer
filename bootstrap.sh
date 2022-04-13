#!/bin/sh

PREFIX=$PWD/sysroot

git submodule init
git submodule update
pushd libusb
./autogen.sh
./configure --prefix="$PREFIX"
make install
popd
rm -rf libuvc/build
mkdir libuvc/build
pushd libuvc/build
CMAKE_PREFIX_PATH="$PREFIX" cmake .. -DENABLE_UVC_DEBUGGING=on -DCMAKE_DISABLE_FIND_PACKAGE_JpegPkg=true
make
cmake --install . --prefix "$PREFIX"
popd
rm "$PREFIX/lib/"*.dylib
