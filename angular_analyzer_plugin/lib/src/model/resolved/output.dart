import 'package:analyzer/dart/ast/ast.dart' as dart;
import 'package:analyzer/dart/element/element.dart' as dart;
import 'package:analyzer/dart/element/type.dart' as dart;
import 'package:analyzer/src/generated/source.dart' show SourceRange;
import 'package:angular_analyzer_plugin/src/model/syntactic/output.dart'
    as syntactic;
import 'package:meta/meta.dart';

/// The resolved model for an Angular output.
///
/// ```dart
///   @Output('optionalName')
///   Stream<EventType> fieldName; // may be a getter only
/// ```
///
/// In addition to the unresolved syntactic information, this tracks references
/// to the underlying getter and event type of the output.
class Output extends syntactic.Output {
  /// The getter element that backs the input.
  final dart.PropertyAccessorElement getter;

  /// The getter should return `Stream<T>` where `T` is the event type.
  final dart.DartType eventType;

  Output(
      {@required String name,
      @required SourceRange nameRange,
      @required this.getter,
      @required this.eventType})
      : super(
            name: name,
            nameRange: nameRange,
            getterName: getter.name,
            getterRange: new SourceRange(getter.nameOffset, getter.nameLength));

  @override
  String toString() => 'Output($name, $getter)';
}
