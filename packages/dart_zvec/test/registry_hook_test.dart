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
  Future<void> Function(BuildInput, BuildOutputBuilder)? compileFromSource,
}) => testCodeBuildHook(
  targetOS: os,
  targetArchitecture: architecture,
  mainMethod: (args) => build(
    args,
    (input, output) => addCollectionRegistry(
      input,
      output,
      prebuiltRoot: prebuiltRoot,
      compileFromSource: compileFromSource,
    ),
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

  // The compiler is injected so these tests do not depend on what the host
  // machine has installed.
  Future<void> failingCompiler(BuildInput _, BuildOutputBuilder _) =>
      Future.error(Exception('No compiler configured'));

  test('falls back to compiling, and says so, when there is no prebuilt '
      'library and the compiler fails', () async {
    await expectLater(
      _run(
        prebuiltRoot: root.uri,
        os: OS.linux,
        architecture: Architecture.x64,
        compileFromSource: failingCompiler,
        check: (_, _) {},
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('no prebuilt'),
            contains('C++ compiler'),
            contains('No compiler configured'),
          ),
        ),
      ),
    );
  });

  test('compiles the source when there is no prebuilt library', () async {
    var compiled = 0;
    await _run(
      prebuiltRoot: root.uri,
      os: OS.linux,
      architecture: Architecture.x64,
      compileFromSource: (_, _) async => compiled++,
      check: (_, output) => expect(output.assets.code, isEmpty),
    );
    expect(compiled, 1);
  });

  test('ignores an empty prebuilt file and compiles instead', () async {
    final target = prebuiltRegistryPath(OS.linux, Architecture.x64);
    File('${root.path}/$target')
      ..createSync(recursive: true)
      ..writeAsBytesSync([]);
    var compiled = 0;
    await _run(
      prebuiltRoot: root.uri,
      os: OS.linux,
      architecture: Architecture.x64,
      compileFromSource: (_, _) async => compiled++,
      check: (_, output) => expect(output.assets.code, isEmpty),
    );
    expect(compiled, 1);
  });

  test('does not compile when a prebuilt library exists', () async {
    final target = prebuiltRegistryPath(OS.linux, Architecture.x64);
    File('${root.path}/$target')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    await _run(
      prebuiltRoot: root.uri,
      os: OS.linux,
      architecture: Architecture.x64,
      compileFromSource: failingCompiler,
      check: (_, output) => expect(output.assets.code, hasLength(1)),
    );
  });
}
