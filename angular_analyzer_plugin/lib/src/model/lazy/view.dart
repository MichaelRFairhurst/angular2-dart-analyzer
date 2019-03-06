import 'package:analyzer/dart/ast/ast.dart' show Annotation;
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/generated/source.dart' show SourceRange, Source;
import 'package:analyzer/src/generated/source.dart' show SourceRange, Source;
import 'package:angular_analyzer_plugin/src/model.dart' hide View;
import 'package:angular_analyzer_plugin/src/model.dart' as resolved;
import 'package:angular_analyzer_plugin/src/model/lazy/component.dart' as lazy;

class View implements resolved.View {
  final lazy.Component _component;

  View(this._component);

  @override
  Annotation get annotation => _component.load().view.annotation;

  @override
  ClassElement get classElement => _component.load().view.classElement;

  @override
  Component get component => _component.load().view.component;

  @override
  List<AbstractDirective> get directives => _component.load().view.directives;

  @override
  DirectivesStrategy get directivesStrategy =>
      _component.load().view.directivesStrategy;

  @override
  Map<String, List<AbstractDirective>> get elementTagsInfo =>
      _component.load().view.elementTagsInfo;

  @override
  int get end => _component.load().view.end;

  @override
  List<ExportedIdentifier> get exports => _component.load().view.exports;

  @override
  List<PipeReference> get pipeReferences =>
      _component.load().view.pipeReferences;

  @override
  List<Pipe> get pipes => _component.load().view.pipes;

  @override
  Source get source => _component.load().view.source;

  @override
  Template get template => _component.load().view.template;

  @override
  set template(v) => _component.load().view.template = v;

  @override
  int get templateOffset => _component.load().view.templateOffset;

  @override
  Source get templateSource => _component.load().view.templateSource;

  @override
  String get templateText => _component.load().view.templateText;

  @override
  Source get templateUriSource => _component.load().view.templateUriSource;

  @override
  SourceRange get templateUrlRange => _component.load().view.templateUrlRange;
}
