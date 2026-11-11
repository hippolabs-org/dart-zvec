import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const registryAssetName = 'src/collection_registry.dart';
const registryLibraryName = 'dart_zvec_collection_registry';

/// Location of the prebuilt registry for [target], relative to the package
/// root. Published packages ship these files; git checkouts do not.
String prebuiltRegistryPath(OS os, Architecture architecture) {
  final libraryFile = os.libraryFileName(
    registryLibraryName,
    DynamicLoadingBundled(),
  );
  return 'native/prebuilt/${os.name}_${architecture.name}/$libraryFile';
}

/// Adds the native collection registry as a code asset.
///
/// A prebuilt library from `native/prebuilt` is used when the package ships
/// one for the target, so no C++ compiler is needed. Other targets, and
/// checkouts without prebuilt binaries, compile `native/collection_registry.cpp`.
///
/// [prebuiltRoot] overrides the directory that contains `native/prebuilt`, and
/// [compileFromSource] replaces the compiler run; both exist for tests.
Future<void> addCollectionRegistry(
  BuildInput input,
  BuildOutputBuilder output, {
  Uri? prebuiltRoot,
  Future<void> Function(BuildInput, BuildOutputBuilder)? compileFromSource,
}) async {
  final target = input.config.code;
  final relativePath = prebuiltRegistryPath(
    target.targetOS,
    target.targetArchitecture,
  );
  final prebuilt = File.fromUri(
    (prebuiltRoot ?? input.packageRoot).resolve(relativePath),
  );
  if (prebuilt.existsSync() && prebuilt.lengthSync() > 0) {
    final library = File.fromUri(
      input.outputDirectory.resolve(prebuilt.uri.pathSegments.last),
    );
    library.parent.createSync(recursive: true);
    prebuilt.copySync(library.path);
    output.dependencies.add(prebuilt.absolute.uri);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: registryAssetName,
        linkMode: DynamicLoadingBundled(),
        file: library.absolute.uri,
      ),
    );
    return;
  }

  try {
    await (compileFromSource ?? _compile)(input, output);
  } catch (error) {
    throw StateError(
      'dart_zvec has no prebuilt collection registry for '
      '${target.targetOS.name}/${target.targetArchitecture.name} '
      '(expected $relativePath), and compiling native/collection_registry.cpp '
      'failed. Install a C++ compiler for this target or use a published '
      'package version that ships a prebuilt binary for it. Cause: $error',
    );
  }
}

Future<void> _compile(BuildInput input, BuildOutputBuilder output) =>
    CBuilder.library(
      name: registryLibraryName,
      assetName: registryAssetName,
      language: Language.cpp,
      std: 'c++17',
      sources: ['native/collection_registry.cpp'],
    ).run(input: input, output: output);
