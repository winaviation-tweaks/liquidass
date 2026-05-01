#!/bin/zsh
set -e
if [[ "$1" == "rootless" || -z "$1" ]]; then
    make clean
    make package ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
fi
if [[ "$1" == "rootful" || -z "$1" ]]; then
    make clean
    make package ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1
fi
# this only works if you got the roothide theos fork: https://github.com/roothide/Developer
if [[ "$1" == "roothide" || -z "$1" ]]; then
    make clean
    make package ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
fi
