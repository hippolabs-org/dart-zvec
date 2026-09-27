import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

const _version = 'v0.7.0';
const _assetName = 'src/bindings.dart';

// SHA-256 digests published with the upstream Zvec release assets.
const _archives = <String, String>{
  'zvec-sdk-osx-arm64.tar.gz':
      'ac909c57e084bb39f7f98ef89b28db322df88348254158eedefa9c00e2c34dfc',
  'zvec-sdk-linux-amd64.tar.gz':
      'db9472ef2146b8f435b45b47a644eb7a75eb84b9946334debfcfc21112cec7f9',
  'zvec-sdk-linux-arm64.tar.gz':
      '9a2a2867fb6ddb53212029b7f50eac288ad86bebfccb6ea6d52b3f35c4e026a8',
  'zvec-sdk-windows-amd64.zip':
      '549f0893a376c8e5b4cf1e685ef55ca37f41a39f5e016632ac1f762ad703d551',
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final target = input.config.code;
    final (archiveName, libraryName) = switch ((
      target.targetOS,
      target.targetArchitecture,
    )) {
      (OS.macOS, Architecture.arm64) => (
        'zvec-sdk-osx-arm64.tar.gz',
        'libzvec_c_api.dylib',
      ),
      (OS.linux, Architecture.x64) => (
        'zvec-sdk-linux-amd64.tar.gz',
        'libzvec_c_api.so',
      ),
      (OS.linux, Architecture.arm64) => (
        'zvec-sdk-linux-arm64.tar.gz',
        'libzvec_c_api.so',
      ),
      (OS.windows, Architecture.x64) => (
        'zvec-sdk-windows-amd64.zip',
        'libzvec_c_api.dll',
      ),
      _ => throw UnsupportedError(
        'Zvec $_version has no Dart native asset for '
        '${target.targetOS}/${target.targetArchitecture}.',
      ),
    };

    final cache = File.fromUri(
      input.outputDirectoryShared.resolve('zvec/$_version/$archiveName'),
    );
    cache.parent.createSync(recursive: true);
    if (!cache.existsSync() ||
        !_verified(cache.readAsBytesSync(), _archives[archiveName]!)) {
      final uri = Uri.parse(
        'https://github.com/alibaba/zvec/releases/download/$_version/$archiveName',
      );
      final bytes = await _download(uri);
      if (!_verified(bytes, _archives[archiveName]!)) {
        throw StateError('SHA-256 verification failed for $uri');
      }
      cache.writeAsBytesSync(bytes, flush: true);
    }

    final archiveBytes = cache.readAsBytesSync();
    final archive = archiveName.endsWith('.zip')
        ? ZipDecoder().decodeBytes(archiveBytes)
        : TarDecoder().decodeBytes(GZipDecoder().decodeBytes(archiveBytes));
    final entry = archive.files.where(
      (file) =>
          file.isFile &&
          file.name.replaceAll('\\', '/').split('/').last == libraryName,
    );
    if (entry.length != 1) {
      throw StateError(
        'Expected exactly one $libraryName in $archiveName, found ${entry.length}.',
      );
    }
    final library = File.fromUri(input.outputDirectory.resolve(libraryName));
    library.parent.createSync(recursive: true);
    library.writeAsBytesSync(entry.single.content, flush: true);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: library.absolute.uri,
      ),
    );
  });
}

bool _verified(List<int> bytes, String expected) =>
    sha256.convert(bytes).toString() == expected;

Future<List<int>> _download(Uri uri) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    return await response.expand((chunk) => chunk).toList();
  } finally {
    client.close();
  }
}
