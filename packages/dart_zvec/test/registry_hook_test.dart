import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../hook/src/collection_registry.dart';

// Runs addCollectionRegistry through the hook protocol with no C compiler
// configured, the situation of a Docker image without a toolchain.
Future<void> _run({
  required Uri prebuiltRoot,
  required OS os,
  required Architecture architecture,
  required void Function(BuildInput, BuildOutput) check,
}) => testCodeBuildHook(
  targetOS: os,
  targetArchitecture: architecture,
  mainMethod: (args) => build(
    args,
    (input, output) =>
        addCollectionRegistry(input, output, prebuiltRoot: prebuiltRoot),
  ),
  check: check,
);

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('registry_hook'));
  tearDown(() => root.deleteSync(recursive: true));

  for (final (os, architecture) in [
    (OS.linux, Architecture.x64),
    (OS.linux, Architecture.arm64),
    (OS.macOS, Architecture.arm64),
    (OS.macOS, Architecture.x64),
    (OS.windows, Architecture.x64),
    (OS.windows, Architecture.arm64),
  ]) {
    test('uses the prebuilt library for ${os.name}/${architecture.name} '
        'without a compiler', () async {
      final target = prebuiltRegistryPath(os, architecture);
      File('${root.path}/$target')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);

      await _run(
        prebuiltRoot: root.uri,
        os: os,
        architecture: architecture,
        check: (input, output) {
          final asset = output.assets.code.single;
          expect(asset.id, 'package:${input.packageName}/$registryAssetName');
          expect(asset.linkMode, isA<DynamicLoadingBundled>());
          expect(File.fromUri(asset.file!).readAsBytesSync(), [1, 2, 3]);
          expect(
            output.dependencies,
            contains(File('${root.path}/$target').absolute.uri),
          );
        },
      );
    });
  }

  test('falls back to compiling, and says so, when there is no prebuilt '
      'library and no compiler', () async {
    await expectLater(
      _run(
        prebuiltRoot: root.uri,
        os: OS.linux,
        architecture: Architecture.x64,
        check: (_, _) {},
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('no prebuilt collection registry'),
            contains('C++ compiler'),
          ),
        ),
      ),
    );
  });

  test('ignores an empty prebuilt file', () async {
    final target = prebuiltRegistryPath(OS.linux, Architecture.x64);
    File('${root.path}/$target')
      ..createSync(recursive: true)
      ..writeAsBytesSync([]);
    await expectLater(
      _run(
        prebuiltRoot: root.uri,
        os: OS.linux,
        architecture: Architecture.x64,
        check: (_, _) {},
      ),
      throwsStateError,
    );
  });
}
