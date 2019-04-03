import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:angular_analyzer_plugin/src/model.dart' as resolved;

class Pipe implements resolved.Pipe {
  @override
  final String pipeName;

  @override
  final int pipeNameOffset;

  resolved.Pipe Function() linkFn;

  @override
  ClassElement classElement;

  resolved.Pipe _linkedPipe;

  Pipe(this.pipeName, this.pipeNameOffset, this.linkFn);

  bool get isLinked => _linkedPipe != null;

  @override
  bool get isPure => load().isPure;

  @override
  List<DartType> get optionalArgumentTypes => load().optionalArgumentTypes;

  @override
  set optionalArgumentTypes(List<DartType> _optionalArgumentTypes) {
    throw UnsupportedError(
        'lazy directives should not change [optionalArgumentTypes]');
  }

  @override
  DartType get requiredArgumentType => load().requiredArgumentType;

  @override
  set requiredArgumentType(DartType _requiredArgumentType) {
    throw UnsupportedError(
        'lazy directives should not change [requiredArgumentType]');
  }

  @override
  DartType get transformReturnType => load().transformReturnType;

  @override
  set transformReturnType(DartType _transformReturnType) {
    throw UnsupportedError(
        'lazy directives should not change [transformReturnType]');
  }

  @override
  bool operator ==(Object other) =>
      other is Pipe && other.classElement == classElement;

  resolved.Pipe load() => _linkedPipe ??= linkFn();
}
