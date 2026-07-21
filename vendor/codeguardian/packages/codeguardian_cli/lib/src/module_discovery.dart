import 'dart:io';

import 'package:path/path.dart' as p;

/// A unit of a project the `improve` pipeline runs over independently: a
/// sub-package, a `lib/` feature folder, or the whole project.
class Module {
  /// Creates a module.
  const Module({required this.name, required this.path});

  /// A short, human-facing identifier (the directory's basename) -- also what
  /// `--module` matches against.
  final String name;

  /// Absolute path to the module's directory (the subtree analyzed for it).
  final String path;

  /// A JSON-serializable representation.
  Map<String, dynamic> toJson() => {'name': name, 'path': path};

  @override
  String toString() => 'Module($name, $path)';
}

/// Directories that are never modules: VCS/build/tooling metadata and the
/// per-platform host projects a Flutter app carries.
const _ignoredDirs = {
  '.git', '.dart_tool', 'build', '.idea', '.vscode', '.fvm', //
  'ios', 'android', 'macos', 'windows', 'linux', 'web', //
};

/// Splits [root] into the modules the pipeline should process.
///
/// Detection, in order:
///  1. **Sub-packages** -- any directory beneath [root] (other than [root]
///     itself) that has its own `pubspec.yaml`. Covers melos/workspace
///     monorepos. Each such directory is a module.
///  2. **`lib/` feature folders** -- if there are no sub-packages but
///     `<root>/lib/` has subdirectories, each one is a module (feature-first
///     single-package apps).
///  3. **Whole project** -- otherwise a single module covering [root].
///
/// When [only] is non-empty, the result is restricted to modules whose [name]
/// is listed; an [ArgumentError] naming the available modules is thrown if any
/// requested name doesn't exist.
List<Module> discoverModules(String root, {List<String> only = const []}) {
  final absoluteRoot = p.normalize(p.absolute(root));

  var modules = _subPackages(absoluteRoot);
  if (modules.isEmpty) modules = _libFeatureFolders(absoluteRoot);
  if (modules.isEmpty) {
    modules = [Module(name: p.basename(absoluteRoot), path: absoluteRoot)];
  }

  modules.sort((a, b) => a.name.compareTo(b.name));

  if (only.isEmpty) return modules;

  final byName = {for (final m in modules) m.name: m};
  final selected = <Module>[];
  for (final name in only) {
    final module = byName[name];
    if (module == null) {
      final available = byName.keys.join(', ');
      throw ArgumentError(
        "Unknown module '$name'. Available modules: $available",
      );
    }
    selected.add(module);
  }
  return selected;
}

List<Module> _subPackages(String root) {
  final modules = <Module>[];
  void walk(Directory dir) {
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (_ignoredDirs.contains(name)) continue;
      if (File(p.join(entity.path, 'pubspec.yaml')).existsSync()) {
        modules.add(Module(name: name, path: entity.path));
        // A package is a leaf for module purposes -- don't descend into a
        // package's own subdirectories looking for more.
        continue;
      }
      walk(entity);
    }
  }

  walk(Directory(root));
  return modules;
}

List<Module> _libFeatureFolders(String root) {
  final lib = Directory(p.join(root, 'lib'));
  if (!lib.existsSync()) return [];
  return [
    for (final entity in lib.listSync(followLinks: false))
      if (entity is Directory && !_ignoredDirs.contains(p.basename(entity.path)))
        Module(name: p.basename(entity.path), path: entity.path),
  ];
}
