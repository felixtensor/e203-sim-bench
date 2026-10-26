# Optional prebuilt models

Reference models target Apple Silicon macOS. They are release assets, not Git files. A published asset URL and SHA-256 are required:

```sh
make download-models MODEL_URL=https://github.com/felixtensor/e203-sim-bench/releases/download/TAG/e203-models-macos-arm64.tar.gz MODEL_SHA256=RELEASE_SHA256
make quick
```

Replace `TAG` and the digest with an actual release. Until one is published, use the source flow in the README.

To prepare an asset locally:

```sh
make package-models CIRCT_BIN=/path/to/circt/build/bin
```

This creates `build/e203-models-macos-arm64.tar.gz` with two models, one benchmark binary, and `SHA256SUMS`. It rejects models containing personal home paths. The downloader verifies the archive digest and file names before extraction, then checks each extracted file. These assets are separate from the original measured binaries.
