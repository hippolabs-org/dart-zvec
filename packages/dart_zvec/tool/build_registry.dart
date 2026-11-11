// Builds the native collection registry as a standalone shared library.
//
// CI and local use run the same command:
//
//   dart tool/build_registry.dart [--os macos|linux|windows]
//       [--arch arm64|x64] [--out <dir>] [--cxx <compiler>] [--verify]
//
// The defaults build for the host into `native/prebuilt/<os>_<arch>/`, the
// location the build hook reads. The compiler is the platform's own: clang++
// on macOS, g++ on Linux and MSVC `cl` on Windows (run it from a Visual Studio
// developer prompt; for arm64 cross builds use the matching `x64_arm64` one).
//
// Portability: Linux links libstdc++/libgcc statically, macOS targets 13.0 and
// Windows links the CRT statically (/MT), so the library needs only the system
// C library. `--verify` checks that and, when the target is the host, loads the
// library and calls it.
import 'dart:ffi';
import 'dart:io';

const _name = 'dart_zvec_collection_registry';
const _source = 'native/collection_registry.cpp';
const _macosMinimum = '13.0';
// Highest glibc symbol version the Linux binary may require. Debian 12 and
// Ubuntu 22.04 ship 2.35; 2.34 is the oldest that merged libpthread.
const _glibcCeiling = (2, 35);
const _exports = [
  'dart_zvec_track',
  'dart_zvec_close_tracked',
  'dart_zvec_close_all_tracked',
  'dart_zvec_is_tracked',
];

Future<void> main(List<String> args) async {
  final options = _parse(args);
  final os = options['os'] ?? _hostOs();
  final arch = options['arch'] ?? _hostArch();
  if (!{'macos', 'linux', 'windows'}.contains(os) ||
      !{'arm64', 'x64'}.contains(arch)) {
    _fail('Unsupported target $os/$arch.');
  }
  final root = File.fromUri(Platform.script).parent.parent.uri;
  final out = Directory(
    options['out'] ?? root.resolve('native/prebuilt/${os}_$arch').toFilePath(),
  )..createSync(recursive: true);
  final file = switch (os) {
    'macos' => 'lib$_name.dylib',
    'linux' => 'lib$_name.so',
    _ => '$_name.dll',
  };
  final output = File('${out.absolute.path}${Platform.pathSeparator}$file');
  if (output.existsSync()) output.deleteSync();
  final source = root.resolve(_source).toFilePath();

  switch (os) {
    case 'macos':
      await _run(options['cxx'] ?? 'clang++', [
        '-std=c++17',
        '-O2',
        '-shared',
        '-fPIC',
        '-fvisibility=hidden',
        '-arch',
        arch == 'arm64' ? 'arm64' : 'x86_64',
        '-mmacosx-version-min=$_macosMinimum',
        '-Wl,-headerpad_max_install_names',
        '-install_name',
        '@rpath/$file',
        '-o',
        output.path,
        source,
      ]);
    case 'linux':
      await _run(options['cxx'] ?? 'g++', [
        '-std=c++17',
        '-O2',
        '-shared',
        '-fPIC',
        '-fvisibility=hidden',
        '-static-libstdc++',
        '-static-libgcc',
        '-Wl,--exclude-libs,ALL',
        '-Wl,-z,relro,-z,now',
        '-Wl,-soname,$file',
        '-o',
        output.path,
        source,
      ]);
    default:
      final work = Directory.systemTemp.createTempSync('dart_zvec_registry');
      try {
        await _run(options['cxx'] ?? 'cl', [
          '/nologo',
          '/std:c++17',
          '/O2',
          '/MT',
          '/EHsc',
          '/LD',
          '/Fo${work.path}${Platform.pathSeparator}',
          source,
          '/Fe:${output.path}',
          '/link',
          '/INCREMENTAL:NO',
          '/IMPLIB:${work.path}${Platform.pathSeparator}$_name.lib',
        ]);
      } finally {
        work.deleteSync(recursive: true);
      }
  }
  stdout.writeln('Built ${output.path}');

  if (options.containsKey('verify')) {
    await _verify(output, os, arch);
    stdout.writeln('Verified ${output.path}');
  }
}

Future<void> _verify(File library, String os, String arch) async {
  if (library.lengthSync() == 0) _fail('${library.path} is empty.');
  switch (os) {
    case 'linux':
      final needed = RegExp(r'\(NEEDED\)\s+Shared library: \[(.+?)\]');
      final dynamic = await _capture('readelf', ['-d', library.path]);
      const allowed = {
        'libc.so.6',
        'libm.so.6',
        'libpthread.so.0',
        'libdl.so.2',
      };
      for (final m in needed.allMatches(dynamic)) {
        if (!allowed.contains(m.group(1)) &&
            !m.group(1)!.startsWith('ld-linux')) {
          _fail('Unexpected runtime dependency ${m.group(1)}.');
        }
      }
      final symbols = await _capture('objdump', ['-T', library.path]);
      var max = (0, 0);
      for (final m in RegExp(r'GLIBC_(\d+)\.(\d+)').allMatches(symbols)) {
        final v = (int.parse(m.group(1)!), int.parse(m.group(2)!));
        if (v.$1 > max.$1 || (v.$1 == max.$1 && v.$2 > max.$2)) max = v;
      }
      if (max.$1 > _glibcCeiling.$1 ||
          (max.$1 == _glibcCeiling.$1 && max.$2 > _glibcCeiling.$2)) {
        _fail(
          'Requires GLIBC_${max.$1}.${max.$2}, above the '
          '${_glibcCeiling.$1}.${_glibcCeiling.$2} ceiling.',
        );
      }
      stdout.writeln('  glibc symbols need at most ${max.$1}.${max.$2}');
      _checkExports(symbols);
    case 'macos':
      final libs = await _capture('otool', ['-L', library.path]);
      for (final line in libs.split('\n').skip(1)) {
        final dep = line.trim();
        if (dep.isEmpty || dep.startsWith('@rpath/')) continue;
        if (!dep.startsWith('/usr/lib/libSystem') &&
            !dep.startsWith('/usr/lib/libc++')) {
          _fail('Unexpected runtime dependency $dep.');
        }
      }
      final load = await _capture('otool', ['-l', library.path]);
      final minos = RegExp(r'minos (\d+)\.(\d+)').firstMatch(load);
      if (minos == null || int.parse(minos.group(1)!) > 13) {
        _fail('Deployment target is not <= $_macosMinimum.');
      }
      _checkExports(await _capture('nm', ['-gU', library.path]));
      // Dart and Flutter rewrite install names when bundling, which needs
      // spare header space.
      final copy = Directory.systemTemp.createTempSync('registry_verify');
      try {
        final probe = File('${copy.path}/${library.uri.pathSegments.last}')
          ..writeAsBytesSync(library.readAsBytesSync());
        await _capture('install_name_tool', [
          '-id',
          '/${'long/' * 60}${probe.uri.pathSegments.last}',
          probe.path,
        ]);
      } finally {
        copy.deleteSync(recursive: true);
      }
    default:
      final deps = await _capture('dumpbin', [
        '/nologo',
        '/dependents',
        library.path,
      ]);
      if (RegExp(
        r'vcruntime|msvcp|ucrtbase',
        caseSensitive: false,
      ).hasMatch(deps)) {
        _fail('The library links the CRT dynamically.');
      }
      _checkExports(
        await _capture('dumpbin', ['/nologo', '/exports', library.path]),
      );
  }

  if (os != _hostOs() || arch != _hostArch()) {
    stdout.writeln('  cross build: not loaded');
    return;
  }
  final lib = DynamicLibrary.open(library.absolute.path);
  for (final symbol in _exports) {
    lib.lookup<NativeFunction<Void Function()>>(symbol);
  }
  // With nothing tracked the registry is a no-op that reports success.
  final isTracked = lib
      .lookupFunction<Int32 Function(Int64), int Function(int)>(
        'dart_zvec_is_tracked',
      );
  final closeAll = lib.lookupFunction<Int32 Function(), int Function()>(
    'dart_zvec_close_all_tracked',
  );
  if (isTracked(1) != 0 || closeAll() != 0) {
    _fail('The registry does not behave as expected when empty.');
  }
  stdout.writeln('  loaded and called');
}

void _checkExports(String listing) {
  for (final symbol in _exports) {
    if (!listing.contains(symbol)) _fail('Missing export $symbol.');
  }
}

Map<String, String> _parse(List<String> args) {
  final result = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) _fail('Unexpected argument $arg.');
    final key = arg.substring(2);
    result[key] = key == 'verify' ? '' : args[++i];
  }
  return result;
}

String _hostOs() => switch (Platform.operatingSystem) {
  'macos' => 'macos',
  'linux' => 'linux',
  'windows' => 'windows',
  final other => _fail('Unsupported host $other.'),
};

String _hostArch() {
  final abi = Abi.current().toString();
  return abi.endsWith('arm64') ? 'arm64' : 'x64';
}

Future<void> _run(String executable, List<String> arguments) async {
  stdout.writeln('\$ $executable ${arguments.join(' ')}');
  final result = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
  ).then((p) => p.exitCode);
  if (result != 0) _fail('$executable exited with $result.');
}

Future<String> _capture(String executable, List<String> arguments) async {
  final result = await Process.run(
    executable,
    arguments,
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) _fail('$executable failed: ${result.stderr}');
  return '${result.stdout}';
}

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(1);
}
