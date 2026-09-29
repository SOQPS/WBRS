// Read-only developer tooling uses the analyzer already pinned by build_runner.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Inventory only. This does not rewrite enum values, user data or payment code.
void main() {
  const excluded = <String>[
    'lib/app/widgets/oplata.dart',
    'lib/app/widgets/robokassa_webview.dart',
    'lib/migrations/',
    'lib/firebase_options.dart',
    'lib/localization/',
  ];
  final rows = <Map<String, Object?>>[];
  for (final file
      in Directory('lib').listSync(recursive: true).whereType<File>()) {
    final path = file.path.replaceAll('\\', '/');
    if (!path.endsWith('.dart') || excluded.any(path.startsWith)) continue;
    final source = file.readAsStringSync();
    final parsed = parseString(content: source, throwIfDiagnostics: false);
    parsed.unit.accept(_Strings((node, value) {
      if (!RegExp('[А-Яа-яЁё]').hasMatch(value)) return;
      final line = parsed.lineInfo.getLocation(node.offset).lineNumber;
      final parent = node.parent;
      final rawContext = parent?.parent?.toSource() ?? node.toSource();
      final context =
          rawContext.length > 300 ? rawContext.substring(0, 300) : rawContext;
      rows.add({
        'file': path,
        'line': line,
        'text': value,
        'interpolated': node is StringInterpolation,
        'localized': parent is ArgumentList &&
            parent.parent is MethodInvocation &&
            (parent.parent as MethodInvocation).methodName.name == 'tr',
        'context': context
      });
    }));
  }
  rows.sort((a, b) =>
      '${a['file']}:${a['line']}'.compareTo('${b['file']}:${b['line']}'));
  final unique = rows.map((row) => row['text'] as String).toSet().toList()
    ..sort();
  final output = Directory('verification/stage2')..createSync(recursive: true);
  File('${output.path}/ui_string_inventory.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'note':
        'Review candidates: includes persisted enums, errors and data keys; only UI occurrences may be translated. Payment gateway files, legal assets and user content excluded. Shop UI labels are included; monetary logic is not rewritten.',
    'occurrences': rows.length,
    'uniqueCandidates': unique.length,
    'strings': rows
  }));
  File('${output.path}/ui_string_candidates.txt')
      .writeAsStringSync(unique.join('\n'));
  stdout.writeln(
      'UI inventory: ${rows.length} occurrences, ${unique.length} unique candidates.');
}

class _Strings extends RecursiveAstVisitor<void> {
  _Strings(this.add);
  final void Function(AstNode, String) add;
  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    add(node, node.stringValue ?? node.toSource());
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    add(node, node.value);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    add(node, node.toSource());
    super.visitStringInterpolation(node);
  }
}
