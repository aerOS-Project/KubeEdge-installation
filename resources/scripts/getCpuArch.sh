#!/bin/bash
arch=$(uname -m)
if [[ $arch == x86_64* ]]; then
  echo "amd64"
elif [[ $arch == aarch64 ]]; then
  echo "arm64"
elif  [[ $arch == aarch32 ]]; then
  echo "arm32"
fi
