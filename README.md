# dart-zvec

Pure Dart bindings for the embedded [Zvec](https://github.com/alibaba/zvec) vector search engine. The repository is a Dart Pub workspace managed with Melos. It has no Flutter dependency.

The publishable package is [`packages/dart_zvec`](packages/dart_zvec). A runnable Dart CLI example is in [`example/dart_zvec_example`](example/dart_zvec_example).

```sh
dart pub get
dart run melos run ci
dart run example/dart_zvec_example/bin/main.dart
```

`dart_zvec` downloads the pinned Zvec v0.7.0 C API release archive during the native build hook, checks its SHA-256 digest, and bundles the platform library as a Dart code asset. Native assets are currently supported on macOS arm64, Linux x64/arm64, and Windows x64. No native binary is checked into this repository or uploaded to the Dart registry.

Publishing to `https://pub.hippolabs.org` is configured in the manual GitHub Actions workflow. It requires a `PUB_CREDENTIALS` secret in the repository or `dart-packages` environment.
