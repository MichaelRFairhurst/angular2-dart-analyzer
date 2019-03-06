import 'package:analyzer/dart/ast/ast.dart'
    show SimpleIdentifier, PrefixedIdentifier, Identifier, Annotation;
import 'package:analyzer/dart/ast/standard_ast_factory.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/dart/ast/token.dart';
import 'package:analyzer/src/dart/resolver/scope.dart';
import 'package:analyzer/src/generated/constant.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/resolver.dart' show TypeProvider;
import 'package:analyzer/src/generated/source.dart' show SourceRange, Source;
import 'package:angular_analyzer_plugin/errors.dart';
import 'package:angular_analyzer_plugin/src/directive_linking.dart';
import 'package:angular_analyzer_plugin/src/ignoring_error_listener.dart';
import 'package:angular_analyzer_plugin/src/model.dart';
import 'package:angular_analyzer_plugin/src/model/lazy/component.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/lazy/directive.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/lazy/pipe.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/syntactic/ng_content.dart';
import 'package:angular_analyzer_plugin/src/selector.dart';
import 'package:angular_analyzer_plugin/src/standard_components.dart';

import 'summary/idl.dart';

/// Resolve the "true" type of an `@Input()` or `@Output()` binding against a
/// context class.
///
/// This handles for instance the case of where a component is generic and its
/// inputs must be instantiated to bounds. It also handles the case where a
/// input is inherited and there's a generic in the inheritance chain that
/// affects the end type.
class BindingTypeResolver {
  final InterfaceType _instantiatedClassType;
  final TypeProvider _typeProvider;
  final AnalysisContext _context;
  final ErrorReporter _errorReporter;

  BindingTypeResolver(ClassElement classElem, TypeProvider typeProvider,
      this._context, this._errorReporter)
      : _instantiatedClassType = _instantiateClass(classElem, typeProvider),
        _typeProvider = typeProvider;

  /// For an `@Output()` on some [getter] of type `Stream<T>`, get the type `T`.
  DartType getEventType(PropertyAccessorElement getter, String name) {
    if (getter != null) {
      // ignore: parameter_assignments
      getter = _instantiatedClassType.lookUpInheritedGetter(getter.name,
          thisType: true);
    }

    if (getter != null && getter.type != null) {
      final returnType = getter.type.returnType;
      if (returnType != null && returnType is InterfaceType) {
        final streamType = _typeProvider.streamType;
        final streamedType = _context.typeSystem
            .mostSpecificTypeArgument(returnType, streamType);
        if (streamedType != null) {
          return streamedType;
        } else {
          _errorReporter.reportErrorForOffset(
              AngularWarningCode.OUTPUT_MUST_BE_STREAM,
              getter.nameOffset,
              getter.name.length,
              [name]);
        }
      } else {
        _errorReporter.reportErrorForOffset(
            AngularWarningCode.OUTPUT_MUST_BE_STREAM,
            getter.nameOffset,
            getter.name.length,
            [name]);
      }
    }

    return _typeProvider.dynamicType;
  }

  /// For an `@Input()` on some [setter] of type `void Function(T)`, get the
  /// type `T`.
  DartType getSetterType(PropertyAccessorElement setter) {
    if (setter != null) {
      // ignore: parameter_assignments
      setter = _instantiatedClassType.lookUpInheritedSetter(setter.name,
          thisType: true);
    }

    if (setter != null && setter.type.parameters.length == 1) {
      return setter.type.parameters[0].type;
    }

    return null;
  }

  static InterfaceType _instantiateClass(
      ClassElement classElement, TypeProvider typeProvider) {
    // TODO use `insantiateToBounds` for better all around support
    // See #91 for discussion about bugs related to bounds
    DartType getBound(TypeParameterElement p) => p.bound == null
        ? typeProvider.dynamicType
        : p.bound.resolveToBound(typeProvider.dynamicType);

    final bounds = classElement.typeParameters.map(getBound).toList();
    return classElement.type.instantiate(bounds);
  }
}

/// Fully resolve the partially resolved instances of the resolved model against
/// the dart element model.
///
/// Note that due to backwards compatibility, this takes a partially resolved
/// model. That partial resolution occurs in [PartialLinker]. Ideally, linking
/// and resolution would be essentially the same phase. That way the resolved
/// model could have static guarantees that its fields are all initialized.
class ResolvePartialModel {
  final StandardAngular _standardAngular;
  final StandardHtml _standardHtml;
  final ErrorReporter _errorReporter;
  final DirectiveProvider _directiveProvider;

  final htmlTypes = new Set.from(['ElementRef', 'Element', 'HtmlElement']);

  ResolvePartialModel(this._standardAngular, this._standardHtml,
      this._errorReporter, this._directiveProvider);

  /// Resolve a [Component] against a [ClassElement].
  Component component(Component component, ClassElement classElement) {
    if (component is lazy.Component) {
      component.classElement = classElement;
    }

    if (component?.view?.templateUriSource != null) {
      final source = component.view.templateUriSource;
      component.ngContents
          .addAll(_directiveProvider.getHtmlNgContent(source.fullName));
    }

    // Also resolve as a directive
    directive(component);
    final scope = new LibraryScope(classElement.library);

    component.view.directivesStrategy.resolve((references) {
      for (final reference in references) {
        // TODO look up directives in current file more efficiently
        _lookupDirectiveByReference(
            reference, scope, component.view.directives);
      }
    }, (constValue, sourceRange) {
      if (constValue == null) {
        return;
      }

      if (constValue.toListValue() != null) {
        _addDirectivesForDartObject(
            component.view.directives, constValue.toListValue(), sourceRange);
      }

      // Note: We don't have to report an error here, because if a non-list
      // was used for the directives parameter, that's a type error in the
      // analyzer.
    });

    component.view.pipeReferences.forEach((reference) =>
        _lookupPipeByReference(reference, scope, component.view.pipes));

    component.contentChilds.addAll(component.contentChildFields
        .map((field) => _contentChild(field, classElement, isSingular: true))
        .where((child) => child != null));
    component.contentChildren.addAll(component.contentChildrenFields
        .map((field) => _contentChild(field, classElement, isSingular: false))
        .where((children) => children != null));

    component.exports.forEach((export) => _export(export, classElement, scope));

    _validateAttributes(component, classElement);

    return component;
  }

  /// Resolve an [AbstractClassDirective] against its [ClassElement].
  AbstractClassDirective directive(AbstractClassDirective directive) {
    // NOTE: Require the Exact type TemplateRef because that's what the
    // injector does.
    directive.looksLikeTemplate = (directive as AbstractClassDirective)
        .classElement
        .constructors
        .any((constructor) => constructor.parameters
            .any((param) => param.type == _standardAngular.templateRef.type));

    final classElement = directive.classElement;
    final bindingSynthesizer = new BindingTypeResolver(
        classElement,
        classElement.context.typeProvider,
        classElement.context,
        _errorReporter);

    for (final supertype in directive.classElement.allSupertypes) {
      final annotatedClass =
          _directiveProvider.getAngularTopLevel(supertype.element);

      if (annotatedClass == null) {
        continue;
      }

      directive.inputs.addAll(annotatedClass.inputs.map(
          (input) => _inheritInput(input, classElement, bindingSynthesizer)));
      directive.outputs.addAll(annotatedClass.outputs.map((output) =>
          _inheritOutput(output, classElement, bindingSynthesizer)));
      directive.contentChildFields.addAll(annotatedClass.contentChildFields);
      directive.contentChildrenFields
          .addAll(annotatedClass.contentChildrenFields);
    }

    return directive;
  }

  /// Resolve a [FunctionalDirective] against its [FunctionElement].
  FunctionalDirective functionalDirective(FunctionalDirective directive) =>
      // NOTE: Require the Exact type TemplateRef because that's what the
      // injector does.
      directive
        ..looksLikeTemplate = directive.functionElement.parameters
            .any((param) => param.type == _standardAngular.templateRef.type);

  /// Resolve a [Pipe] against a [ClassElement].
  ///
  /// Looks for a 'transform' function, and if found, finds all the
  /// important type information needed for resolution of pipe.
  Pipe pipe(Pipe pipe, ClassElement classElement) {
    // Check if 'extends PipeTransform' exists.
    if (!classElement.type.isSubtypeOf(_standardAngular.pipeTransform.type)) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.PIPE_REQUIRES_PIPETRANSFORM,
          pipe.pipeNameOffset,
          pipe.pipeName.length);
    }

    final transformMethod =
        classElement.lookUpMethod('transform', classElement.library);
    if (transformMethod == null) {
      _errorReporter.reportErrorForElement(
          AngularWarningCode.PIPE_REQUIRES_TRANSFORM_METHOD, classElement);
      return pipe;
    }

    pipe.transformReturnType = transformMethod.returnType;
    final parameters = transformMethod.parameters;
    if (parameters == null || parameters.isEmpty) {
      _errorReporter.reportErrorForElement(
          AngularWarningCode.PIPE_TRANSFORM_REQ_ONE_ARG, transformMethod);
    }
    for (final parameter in parameters) {
      // If named or positional
      if (parameter.isNamed) {
        _errorReporter.reportErrorForElement(
            AngularWarningCode.PIPE_TRANSFORM_NO_NAMED_ARGS, parameter);
        continue;
      }
      if (parameters.first == parameter) {
        pipe.requiredArgumentType = parameter.type;
      } else {
        pipe.optionalArgumentTypes.add(parameter.type);
      }
    }
    return pipe;
  }

  void _addDirectiveFromElement(Element element,
      List<AbstractDirective> targetList, SourceRange errorRange) {
    final directive = _directiveProvider.getAngularTopLevel(element);
    if (directive != null) {
      targetList.add(directive as AbstractDirective);
      return;
    } else {
      _errorReporter.reportErrorForOffset(
          element is FunctionElement
              ? AngularWarningCode.FUNCTION_IS_NOT_A_DIRECTIVE
              : AngularWarningCode.TYPE_IS_NOT_A_DIRECTIVE,
          errorRange.offset,
          errorRange.length,
          [element.name]);
    }
  }

  /// Walk the given [value] and add directives into [directives].
  /// Return `true` if success, or `false` the [value] has items that don't
  /// correspond to a directive.
  void _addDirectivesForDartObject(List<AbstractDirective> directives,
      List<DartObject> values, SourceRange errorRange) {
    for (final listItem in values) {
      final typeValue = listItem.toTypeValue();
      final isType =
          typeValue is InterfaceType && typeValue.element is ClassElement;
      final isFunction = listItem.type?.element is FunctionElement;
      final element = isType ? typeValue.element : listItem.type?.element;
      if (isType || isFunction) {
        _addDirectiveFromElement(element, directives, errorRange);
        continue;
      }

      final listValue = listItem.toListValue();
      if (listValue != null) {
        _addDirectivesForDartObject(directives, listValue, errorRange);
        continue;
      }

      _errorReporter.reportErrorForOffset(
        AngularWarningCode.TYPE_LITERAL_EXPECTED,
        errorRange.offset,
        errorRange.length,
      );
    }
  }

  void _addPipeFromElement(
      ClassElement element, List<Pipe> targetList, SourceRange errorRange) {
    final pipe = _directiveProvider.getPipe(element);
    if (directive != null) {
      targetList.add(pipe);
      return;
    } else {
      _errorReporter.reportErrorForOffset(AngularWarningCode.TYPE_IS_NOT_A_PIPE,
          errorRange.offset, errorRange.length, [element.name]);
    }
  }

  /// Walk the given [value] and add directives into [directives].
  /// Return `true` if success, or `false` the [value] has items that don't
  /// correspond to a directive.
  void _addPipesForDartObject(
      List<Pipe> pipes, List<DartObject> values, SourceRange errorRange) {
    for (final listItem in values) {
      final typeValue = listItem.toTypeValue();
      final element = typeValue?.element;
      if (typeValue is InterfaceType && element is ClassElement) {
        _addPipeFromElement(element, pipes, errorRange);
        continue;
      }

      final listValue = listItem.toListValue();
      if (listValue != null) {
        _addPipesForDartObject(pipes, listValue, errorRange);
        continue;
      }

      _errorReporter.reportErrorForOffset(
        AngularWarningCode.TYPE_LITERAL_EXPECTED,
        errorRange.offset,
        errorRange.length,
      );
    }
  }

  void _checkQueriedTypeAssignableTo(DartType setterType,
      DartType annotatedType, ContentChildField field, String annotationName) {
    if (setterType != null && !setterType.isSupertypeOf(annotatedType)) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.INVALID_TYPE_FOR_CHILD_QUERY,
          field.typeRange.offset,
          field.typeRange.length,
          [field.fieldName, annotationName, annotatedType, setterType]);
    }
  }

  ContentChild _contentChild(
      ContentChildField contentChildField, ClassElement classElement,
      {bool isSingular}) {
    final bindingSynthesizer = new BindingTypeResolver(
        classElement,
        classElement.context.typeProvider,
        classElement.context,
        _errorReporter);

    final annotationName = isSingular ? 'ContentChild' : 'ContentChildren';
    final setterTransform = isSingular
        ? _transformSetterTypeSingular
        : _transformSetterTypeMultiple;

    final member = classElement.lookUpSetter(
        contentChildField.fieldName, classElement.library);
    if (member == null) {
      return null;
    }

    final metadata = new List<ElementAnnotation>.from(member.metadata)
      ..addAll(member.variable.metadata);
    final annotations = metadata.where((annotation) =>
        annotation.element?.enclosingElement?.name == annotationName);

    // This can happen for invalid dart
    if (annotations.length != 1) {
      return null;
    }

    final annotation = annotations.first;
    final annotationValue = annotation.computeConstantValue();

    // `constantValue.getField()` doesn't do inheritance. Do that ourself.
    final value = _getSelectorWithInheritance(annotationValue);
    final read = _getReadWithInheritance(annotationValue);
    final transformedType = setterTransform(
        bindingSynthesizer.getSetterType(member),
        contentChildField,
        annotationName,
        classElement.context);

    if (read != null) {
      _checkQueriedTypeAssignableTo(transformedType, read, contentChildField,
          '$annotationName(read: $read)');
    }

    if (value?.toStringValue() != null) {
      if (transformedType == _standardHtml.elementClass.type ||
          transformedType == _standardHtml.htmlElementClass.type ||
          read == _standardHtml.elementClass.type ||
          read == _standardHtml.htmlElementClass.type) {
        if (read == null) {
          _errorReporter.reportErrorForOffset(
              AngularWarningCode.CHILD_QUERY_TYPE_REQUIRES_READ,
              contentChildField.nameRange.offset,
              contentChildField.nameRange.length, [
            contentChildField.fieldName,
            annotationName,
            transformedType.name
          ]);
        }
        return new ContentChild(contentChildField,
            new LetBoundQueriedChildType(value.toStringValue(), read),
            read: read);
      }

      // Take the type -- except, we can't validate DI symbols via `read`.
      final setterType = read == null
          ? transformedType
          : classElement.context.typeProvider.dynamicType;

      return new ContentChild(contentChildField,
          new LetBoundQueriedChildType(value.toStringValue(), setterType),
          read: read);
    } else if (value?.toTypeValue() != null) {
      final type = value.toTypeValue();
      final referencedDirective =
          _directiveProvider.getAngularTopLevel(type.element as ClassElement)
              as AbstractClassDirective;

      AbstractQueriedChildType query;
      if (referencedDirective != null) {
        query = new DirectiveQueriedChildType(referencedDirective);
      } else if (htmlTypes.contains(type.element.name)) {
        query = new ElementQueriedChildType();
      } else if (type.element.name == 'TemplateRef') {
        query = new TemplateRefQueriedChildType();
      } else {
        _errorReporter.reportErrorForOffset(
            AngularWarningCode.UNKNOWN_CHILD_QUERY_TYPE,
            contentChildField.nameRange.offset,
            contentChildField.nameRange.length,
            [contentChildField.fieldName, annotationName]);
        return null;
      }

      _checkQueriedTypeAssignableTo(
          transformedType, read ?? type, contentChildField, annotationName);

      return new ContentChild(contentChildField, query, read: read);
    } else {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.UNKNOWN_CHILD_QUERY_TYPE,
          contentChildField.nameRange.offset,
          contentChildField.nameRange.length,
          [contentChildField.fieldName, annotationName]);
    }
    return null;
  }

  ExportedIdentifier _export(ExportedIdentifier export,
      ClassElement componentClassElement, LibraryScope scope) {
    if (_hasWrongTypeOfPrefix(export, scope)) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.EXPORTS_MUST_BE_PLAIN_IDENTIFIERS,
          export.span.offset,
          export.span.length);
      return null;
    }

    final element = scope.lookup(_getIdentifier(export), null);
    if (element == componentClassElement) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.COMPONENTS_CANT_EXPORT_THEMSELVES,
          export.span.offset,
          export.span.length);
      return null;
    }

    export.element = element;

    return export;
  }

  /// ConstantValue.getField() doesn't look up the inheritance tree. Rather than
  /// hardcoding the inheritance tree in our code, look up the inheritance tree
  /// until either it ends, or we find a "selector" field.
  DartObject _getFieldWithInheritance(DartObject value, String field) {
    final selector = value.getField(field);
    if (selector != null) {
      return selector;
    }

    final _super = value.getField('(super)');
    if (_super != null) {
      return _getFieldWithInheritance(_super, field);
    }

    return null;
  }

  Identifier _getIdentifier(ExportedIdentifier export) => export.prefix == ''
      ? _getSimpleIdentifier(export)
      : _getPrefixedIdentifier(export);

  SimpleIdentifier _getPrefixAsSimpleIdentifier(ExportedIdentifier export) =>
      astFactory.simpleIdentifier(new StringToken(
          TokenType.IDENTIFIER, export.prefix, export.span.offset));

  PrefixedIdentifier _getPrefixedIdentifier(ExportedIdentifier export) =>
      astFactory.prefixedIdentifier(
          _getPrefixAsSimpleIdentifier(export),
          new SimpleToken(
              TokenType.PERIOD, export.span.offset + export.prefix.length),
          _getSimpleIdentifier(export, offset: export.prefix.length + 1));

  /// See [_getFieldWithInheritance]
  DartType _getReadWithInheritance(DartObject value) {
    final constantVal = _getFieldWithInheritance(value, 'read');
    if (constantVal.isNull) {
      return null;
    }

    return constantVal.toTypeValue();
  }

  /// See [_getFieldWithInheritance]
  DartObject _getSelectorWithInheritance(DartObject value) =>
      _getFieldWithInheritance(value, 'selector');

  SimpleIdentifier _getSimpleIdentifier(ExportedIdentifier export,
          {int offset: 0}) =>
      astFactory.simpleIdentifier(new StringToken(TokenType.IDENTIFIER,
          export.identifier, export.span.offset + offset));

  /// Only report false for known non-import-prefix prefixes, the rest get
  /// flagged by the dart analyzer already.
  bool _hasWrongTypeOfPrefix(ExportedIdentifier export, LibraryScope scope) {
    if (export.prefix == '') {
      return false;
    }

    final prefixElement =
        scope.lookup(_getPrefixAsSimpleIdentifier(export), null);

    return prefixElement != null && prefixElement is! PrefixElement;
  }

  InputElement _inheritInput(InputElement input, ClassElement classElement,
      BindingTypeResolver bindingSynthesizer) {
    final setter = classElement.lookUpSetter(
        input.setter.displayName, classElement.library);
    if (setter == null) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.INPUT_ANNOTATION_PLACEMENT_INVALID,
          input.nameOffset,
          input.name.length,
          [input.name]);
      return input;
    }
    return new InputElement(
        input.name,
        input.nameOffset,
        input.nameLength,
        input.source,
        setter,
        new SourceRange(setter.nameOffset, setter.nameLength),
        bindingSynthesizer.getSetterType(setter));
  }

  OutputElement _inheritOutput(OutputElement output, ClassElement classElement,
      BindingTypeResolver bindingSynthesizer) {
    final getter =
        classElement.lookUpGetter(output.getter.name, classElement.library);
    if (getter == null) {
      // Happens when an interface with an output isn't implemented correctly.
      // This will be accompanied by a dart error, so we can just return the
      // original without transformation to prevent cascading errors.
      return output;
    }
    return new OutputElement(
        output.name,
        output.nameOffset,
        output.nameLength,
        output.source,
        getter,
        new SourceRange(getter.nameOffset, getter.nameLength),
        bindingSynthesizer.getEventType(getter, output.name));
  }

  void _lookupDirectiveByReference(DirectiveReference reference,
      LibraryScope scope, List<AbstractDirective> directives) {
    final nameIdentifier = astFactory.simpleIdentifier(
        new StringToken(TokenType.IDENTIFIER, reference.name, 0));
    final prefixIdentifier = astFactory.simpleIdentifier(
        new StringToken(TokenType.IDENTIFIER, reference.prefix, 0));
    final element = scope.lookup(
        reference.prefix == ""
            ? nameIdentifier
            : astFactory.prefixedIdentifier(
                prefixIdentifier, null, nameIdentifier),
        null);

    if (element != null && element.source != null) {
      if (element is ClassElement || element is FunctionElement) {
        _addDirectiveFromElement(element, directives, reference.range);
        return;
      } else if (element is PropertyAccessorElement) {
        element.variable.computeConstantValue();
        final values = element.variable.constantValue?.toListValue();
        if (values != null) {
          _addDirectivesForDartObject(directives, values, reference.range);
          return;
        }
      }
    }

    _errorReporter.reportErrorForOffset(
        AngularWarningCode.TYPE_LITERAL_EXPECTED,
        reference.range.offset,
        reference.range.length);
  }

  void _lookupPipeByReference(
      PipeReference reference, LibraryScope scope, List<Pipe> pipes) {
    final element = scope.lookup(
        astFactory.simpleIdentifier(
            new StringToken(TokenType.IDENTIFIER, reference.identifier, 0)),
        null);

    if (element != null && element.source != null) {
      if (element is ClassElement) {
        _addPipeFromElement(element, pipes, reference.span);
        return;
      } else if (element is PropertyAccessorElement) {
        element.variable.computeConstantValue();
        final values = element.variable.constantValue?.toListValue();
        if (values != null) {
          _addPipesForDartObject(pipes, values, reference.span);
          return;
        }
      }
    }

    _errorReporter.reportErrorForOffset(
        AngularWarningCode.TYPE_LITERAL_EXPECTED,
        reference.span.offset,
        reference.span.length);
  }

  DartType _transformSetterTypeMultiple(DartType setterType,
      ContentChildField field, String annotationName, AnalysisContext context) {
    // construct List<Bottom>, which is a subtype of all List<T>
    final typeProvider = context.typeProvider;
    final listBottom =
        typeProvider.listType.instantiate([typeProvider.bottomType]);

    if (!setterType.isSupertypeOf(listBottom)) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.CONTENT_OR_VIEW_CHILDREN_REQUIRES_LIST,
          field.typeRange.offset,
          field.typeRange.length,
          [field.fieldName, annotationName, setterType]);

      return typeProvider.dynamicType;
    }

    final iterableType = typeProvider.iterableType;

    // get T for setterTypes that extend Iterable<T>
    return context.typeSystem
        .mostSpecificTypeArgument(setterType, iterableType);
  }

  DartType _transformSetterTypeSingular(
          DartType setterType,
          ContentChildField field,
          String annotationName,
          AnalysisContext analysisContext) =>
      setterType;

  void _validateAttributes(
      AbstractDirective directive, ClassElement classElement) {
    for (final constructor in classElement.constructors) {
      for (final parameter in constructor.parameters) {
        for (final annotation in parameter.metadata) {
          if (annotation.element?.enclosingElement?.name != "Attribute") {
            continue;
          }

          final attributeName = annotation
              .computeConstantValue()
              ?.getField("attributeName")
              ?.toStringValue();
          if (attributeName == null) {
            continue;
            // TODO do we ever need to report an error here, or will DAS?
          }

          if (parameter.type.name != "String") {
            _errorReporter.reportErrorForOffset(
                AngularWarningCode.ATTRIBUTE_PARAMETER_MUST_BE_STRING,
                parameter.nameOffset,
                parameter.name.length);
          }

          directive.attributes.add(new AngularElementImpl(attributeName,
              parameter.nameOffset, parameter.nameLength, parameter.source));
        }
      }
    }
  }
}
