// Test-only AST inspection uses the analyzer version already pinned in the lockfile.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Every literal UI localization key exists in the complete catalogs', () {
    final catalog =
        jsonDecode(File('assets/l10n/ru.json').readAsStringSync()) as Map;
    final missing = <String>[];
    for (final file
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.contains('/localization/'))
        continue;
      final parsed = parseString(
          content: file.readAsStringSync(), throwIfDiagnostics: false);
      parsed.unit.accept(_Translations((node) {
        for (final source in _keys(node.argumentList.arguments.first)) {
          if (!catalog.containsKey(source)) {
            missing.add(
                '${file.path}:${parsed.lineInfo.getLocation(node.offset).lineNumber} — $source');
          }
        }
      }));
    }
    expect(missing, isEmpty,
        reason:
            'Untranslated UI keys must be added explicitly in all 23 languages:\n${missing.join('\n')}');
  });
}

Iterable<String> _keys(Expression expression) sync* {
  if (expression is StringLiteral && expression.stringValue != null) {
    yield expression.stringValue!;
  } else if (expression is ConditionalExpression) {
    yield* _keys(expression.thenExpression);
    yield* _keys(expression.elseExpression);
  } else if (expression is BinaryExpression &&
      expression.operator.lexeme == '??') {
    yield* _keys(expression.rightOperand);
  }
}

class _Translations extends RecursiveAstVisitor<void> {
  _Translations(this.found);
  final void Function(MethodInvocation) found;
  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'tr' && node.argumentList.arguments.isNotEmpty)
      found(node);
    super.visitMethodInvocation(node);
  }
}
