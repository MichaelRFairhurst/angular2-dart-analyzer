import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/generated/source.dart' show Source;
import 'package:angular_analyzer_plugin/src/model.dart' hide Pipe;
import 'package:angular_analyzer_plugin/src/model.dart' as resolved;
import 'package:angular_analyzer_plugin/src/model/lazy/view.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/syntactic/ng_content.dart';
import 'package:angular_analyzer_plugin/src/selector.dart';

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
    throw 'not supported';
  }

  @override
  DartType get requiredArgumentType => load().requiredArgumentType;

  @override
  set requiredArgumentType(DartType _requiredArgumentType) {
    throw 'not supported';
  }

  @override
  DartType get transformReturnType => load().transformReturnType;

  @override
  set transformReturnType(DartType _transformReturnType) {
    throw 'not supported';
  }

  @override
  bool operator ==(Object other) =>
      other is Pipe && other.classElement == classElement;

  resolved.Pipe load() {
    return _linkedPipe ??= linkFn();
  }
}
