import 'package:analyzer/error/error.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:angular_analyzer_plugin/src/model.dart';
import 'package:angular_ast/angular_ast.dart' as ng_ast;

/// Look for `<!-- @ngIgnoredErrors -->` and set the codes on [template].
void setIgnoredErrors(Template template, List<ng_ast.TemplateAst> asts) {
  if (asts == null || asts.isEmpty) {
    return;
  }
  for (final ast in asts) {
    if (ast is ng_ast.TextAst && ast.value.trim().isEmpty) {
      continue;
    } else if (ast is ng_ast.CommentAst) {
      var text = ast.value.trim();
      if (text.startsWith('@ngIgnoreErrors')) {
        text = text.substring('@ngIgnoreErrors'.length);
        // Per spec: optional colon
        if (text.startsWith(':')) {
          text = text.substring(1);
        }
        // Per spec: optional commas
        final delim = !text.contains(',') ? ' ' : ',';
        template.ignoredErrors.addAll(
            text.split(delim).map((c) => c.trim().toUpperCase()).toSet());
      }
    } else {
      return;
    }
  }
}

/// Parse an angular AST and store the errors during parse.
class TemplateParser {
  List<ng_ast.StandaloneTemplateAst> rawAst;
  final parseErrors = <AnalysisError>[];

  void parse(String content, Source source, {int offset = 0}) {
    if (offset != null) {
      // ignore: prefer_interpolation_to_compose_strings, parameter_assignments
      content = ' ' * offset + content;
    }
    final exceptionHandler = new ng_ast.RecoveringExceptionHandler();
    rawAst = ng_ast.parse(
      content,
      sourceUrl: source.uri.toString(),
      desugar: false,
      parseExpressions: false,
      exceptionHandler: exceptionHandler,
    ) as List<ng_ast.StandaloneTemplateAst>;

    for (final e in exceptionHandler.exceptions) {
      if (e.errorCode is ng_ast.NgParserWarningCode) {
        parseErrors.add(new AnalysisError(
          source,
          e.offset,
          e.length,
          e.errorCode,
        ));
      }
    }
  }
}
