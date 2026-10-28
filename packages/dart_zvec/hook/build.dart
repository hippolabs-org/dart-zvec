import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

const _version = 'v0.8.0';
const _assetName = 'src/bindings.dart';

// SHA-256 digests published with the upstream Zvec release assets.
const _archives = <String, String>{
  'zvec-sdk-osx-arm64.tar.gz':
      '5f0828e5bf5b0dc11754cc039f43a9de161e2daea5d088e1d48f8effd278d1fc',
  'zvec-sdk-osx-amd64.tar.gz':
      'c758501846b17ad2696ea44bbd99859fe0b312ec837b1eeecff310cff75c7b83',
  'zvec-sdk-linux-amd64.tar.gz':
      'bc7097a293ec1677ac84c46e76afef880359766cd1e1cdf2494ef669237b134a',
  'zvec-sdk-linux-arm64.tar.gz':
      '0055f8135d121d51365edd216429f281341fa47a36a96dec60ddac28b60d0c3b',
  'zvec-sdk-windows-amd64.zip':
      '7fc16b1bf575d3300f4ae4728f09a6a096b67025d508c350c16302c665ccbbe8',
  'zvec-sdk-windows-arm64.zip':
      '43d61816a37b71380e4552f45759e206b57e4b54993f7e8da57d65a466d031e5',
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
      (OS.macOS, Architecture.x64) => (
        'zvec-sdk-osx-amd64.tar.gz',
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
        'zvec_c_api.dll',
      ),
      (OS.windows, Architecture.arm64) => (
        'zvec-sdk-windows-arm64.zip',
        'zvec_c_api.dll',
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
