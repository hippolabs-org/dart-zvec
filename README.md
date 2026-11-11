# dart-zvec

Pure Dart bindings for the embedded [Zvec](https://github.com/alibaba/zvec) vector and BM25 full-text search engine. The repository is a Dart Pub workspace managed with Melos. It has no Flutter dependency.

The publishable package is [`packages/dart_zvec`](packages/dart_zvec). A runnable Dart CLI example is in [`example/dart_zvec_example`](example/dart_zvec_example).

```sh
dart pub get
dart run melos run ci
dart run example/dart_zvec_example/bin/main.dart
```

`dart_zvec` downloads the pinned Zvec v0.8.0 C API release archive during the native build hook, checks its SHA-256 digest, and bundles the platform library as a Dart code asset. Native assets are currently supported on macOS arm64/x64, Linux x64/arm64, and Windows x64/arm64. No native binary is checked into this repository. The Zvec SDK is downloaded at build time, while the small collection registry is built by the publish workflow (`tool/build_registry.dart`, one job per target) and shipped prebuilt inside the published package, so consumers need no C++ compiler.

Publishing to `https://pub.hippolabs.org` is configured in the manual GitHub Actions workflow. It requires a `PUB_CREDENTIALS` secret in the repository or `dart-packages` environment.
