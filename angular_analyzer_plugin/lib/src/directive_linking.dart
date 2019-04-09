import 'package:analyzer/dart/ast/ast.dart'
    show SimpleIdentifier, PrefixedIdentifier, Identifier;
import 'package:analyzer/dart/ast/standard_ast_factory.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/source/source_range.dart';
import 'package:analyzer/src/dart/ast/token.dart';
import 'package:analyzer/src/dart/resolver/scope.dart';
import 'package:analyzer/src/generated/constant.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/source.dart' show SourceRange, Source;
import 'package:angular_analyzer_plugin/errors.dart';
import 'package:angular_analyzer_plugin/src/element_resolver.dart';
import 'package:angular_analyzer_plugin/src/ignoring_error_listener.dart';
import 'package:angular_analyzer_plugin/src/model.dart';
import 'package:angular_analyzer_plugin/src/model/lazy/component.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/lazy/directive.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/lazy/pipe.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/navigable.dart';
import 'package:angular_analyzer_plugin/src/model/syntactic/ng_content.dart';
import 'package:angular_analyzer_plugin/src/selector.dart';
import 'package:angular_analyzer_plugin/src/selector/element_name_selector.dart';
import 'package:angular_analyzer_plugin/src/standard_components.dart';

import 'summary/idl.dart';

/// Link a [Pipe] with the specified [Linker] from its summary & element.
Pipe linkPipe(List<SummarizedPipe> pipeSummaries, ClassElement element,
    TopLevelLinker linker) {
  for (final sum in pipeSummaries) {
    if (sum.decoratedClassName == element.name) {
      return linker.pipe(sum, element);
    }
  }

  return null;
}

/// Link [Pipe]s with the specified [Linker] from a summary & compilation unit.
List<Pipe> linkPipes(List<SummarizedPipe> pipeSummaries,
    CompilationUnitElement compilationUnitElement, TopLevelLinker linker) {
  final pipes = <Pipe>[];

  for (final pipeSum in pipeSummaries) {
    final classElem =
        compilationUnitElement.getType(pipeSum.decoratedClassName);
    pipes.add(linker.pipe(pipeSum, classElem));
  }

  return pipes;
}

/// Link [TopLevel] with the [Linker] from its summary & element.
TopLevel linkTopLevel(
    UnlinkedDartSummary unlinked, Element element, TopLevelLinker linker) {
  if (element is ClassElement) {
    for (final sum in unlinked.directiveSummaries) {
      if (sum.classAnnotations?.className == element.name) {
        return sum.isComponent
            ? linker.component(sum, element)
            : linker.directive(sum, element);
      }
    }

    for (final sum in unlinked.annotatedClasses) {
      if (sum.className == element.name) {
        return linker.annotatedClass(sum, element);
      }
    }
  } else if (element is FunctionElement) {
    for (final sum in unlinked.directiveSummaries) {
      if (sum.functionName == element.name) {
        return linker.functionalDirective(sum, element);
      }
    }
  }

  return null;
}

/// Link [TopLevel]s with the [Linker] from summary & compilation unit.
List<TopLevel> linkTopLevels(UnlinkedDartSummary unlinked,
        CompilationUnitElement compilationUnitElement, TopLevelLinker linker) =>
    unlinked.directiveSummaries.map<TopLevel>((sum) {
      if (sum.isComponent) {
        return linker.component(sum,
            compilationUnitElement.getType(sum.classAnnotations.className));
      } else if (sum.functionName != "") {
        return linker.functionalDirective(
            sum,
            compilationUnitElement.functions
                .singleWhere((f) => f.name == sum.functionName));
      } else {
        return linker.directive(sum,
            compilationUnitElement.getType(sum.classAnnotations.className));
      }
    }).toList()
      ..addAll(unlinked.annotatedClasses.map((sum) => linker.annotatedClass(
          sum, compilationUnitElement.getType(sum.className))));

/// Interface to look up [TopLevel]s by the dart [Element] model.
abstract class DirectiveProvider {
  TopLevel getAngularTopLevel(Element element);
  List<NgContent> getHtmlNgContent(String path);
  Pipe getPipe(ClassElement element);
}

/// Eagerly link+resolve summaries into the resolved model.
///
/// This is used by the lazy linker, as well as by the driver in order to force-
/// -calculate element resolution errors.
///
/// This currently uses [PartialLinker] with [ResolvePartialModel]. However,
/// in an ideal implementation, those would not be distinct stages, and the
/// linker would not be distinct from resolution. That behavior would then all
/// exist here.
class EagerLinker implements TopLevelLinker {
  final DirectiveProvider _directiveProvider;
  final StandardAngular _standardAngular;
  final StandardHtml _standardHtml;
  final ErrorReporter _errorReporter;
  final _ExportLinker _exportLinker;
  final _SubDirectiveLinker _subDirectiveLinker;
  final _SubPipeLinker _subPipeLinker;
  final _ContentChildLinker _contentChildLinker;

  EagerLinker(this._standardAngular, this._standardHtml, this._errorReporter,
      this._directiveProvider)
      : _exportLinker = _ExportLinker(_errorReporter),
        _subDirectiveLinker =
            _SubDirectiveLinker(_directiveProvider, _errorReporter),
        _subPipeLinker = _SubPipeLinker(_directiveProvider, _errorReporter),
        _contentChildLinker = _ContentChildLinker(
            _directiveProvider, _standardHtml, _errorReporter);

  /// Fully link an [AngularAnnotatedClass] from a summary and a [ClassElement].
  @override
  AnnotatedClass annotatedClass(
      SummarizedClassAnnotations classSum, ClassElement classElement) {
    final bindingSynthesizer = new BindingTypeResolver(
        classElement,
        classElement.context.typeProvider,
        classElement.context,
        _errorReporter);

    final inputs = classSum.inputs
        .map((inputSum) => input(inputSum, classElement, bindingSynthesizer))
        .where((inputSum) => inputSum != null)
        .toList();
    final outputs = classSum.outputs
        .map((outputSum) => output(outputSum, classElement, bindingSynthesizer))
        .where((outputSum) => outputSum != null)
        .toList();
    final contentChildFields = classSum.contentChildFields
        .map((contentChildField) => _contentChildLinker
            .link(contentChildField, classElement, isSingular: true))
        .where((child) => child != null)
        .toList();
    final contentChildrenFields = classSum.contentChildrenFields
        .map((contentChildField) => _contentChildLinker
            .link(contentChildField, classElement, isSingular: false))
        .where((children) => children != null)
        .toList();

    return new AnnotatedClass(classElement,
        inputs: inputs,
        outputs: outputs,
        contentChildFields: contentChildFields,
        contentChildrenFields: contentChildrenFields);
  }

  /// Partially link a [Component] from a summary and a [ClassElement].
  @override
  Component component(SummarizedDirective dirSum, ClassElement classElement) {
    assert(dirSum.isComponent);
    final directiveInfo = directive(dirSum, classElement);

    final scope = new LibraryScope(classElement.library);
    final exports = dirSum.exports
        .map((export) => _exportLinker.link(export, classElement, scope))
        .toList();
    final pipes = <Pipe>[];
    dirSum.pipesUse
        .forEach((pipeSum) => _subPipeLinker.link(pipeSum, scope, pipes));
    final subDirectives = <DirectiveBase>[];
    dirSum.subdirectives.forEach(
        (dirSum) => _subDirectiveLinker.link(dirSum, scope, subDirectives));
    Source templateUrlSource;
    SourceRange templateUrlRange;
    if (dirSum.templateUrl != '') {
      templateUrlSource = classElement.context.sourceFactory
          .resolveUri(classElement.library.source, dirSum.templateUrl);
      templateUrlRange =
          new SourceRange(dirSum.templateUrlOffset, dirSum.templateUrlLength);
      if (!templateUrlSource.exists()) {
        _errorReporter.reportErrorForOffset(
          AngularWarningCode.REFERENCED_HTML_FILE_DOESNT_EXIST,
          dirSum.templateUrlOffset,
          dirSum.templateUrlLength,
        );
      }
    }

    final ngContents = dirSum.ngContents
        .map((ngContentSum) => ngContent(ngContentSum, directiveInfo.source))
        .toList();

    return new Component(
      classElement,
      attributes: _collectAttributes(classElement),
      isHtml: false,
      ngContents: ngContents,
      templateText: dirSum.templateText,
      templateTextRange:
          SourceRange(dirSum.templateOffset, dirSum.templateText.length),
      templateUrlSource: templateUrlSource,
      templateUrlRange: templateUrlRange,
      directives: subDirectives,
      exports: exports,
      pipes: pipes,
      contentChildFields: directiveInfo.contentChildFields,
      contentChildrenFields: directiveInfo.contentChildrenFields,
      exportAs: directiveInfo.exportAs,
      selector: directiveInfo.selector,
      inputs: directiveInfo.inputs,
      outputs: directiveInfo.outputs,
      looksLikeTemplate: directiveInfo.looksLikeTemplate,
    );
  }

  /// Partially link [Directive] from summary and [ClassElement].
  @override
  Directive directive(SummarizedDirective dirSum, ClassElement classElement) {
    assert(dirSum.functionName == "");

    final selector = new SelectorParser(
            classElement.source, dirSum.selectorOffset, dirSum.selectorStr)
        .parse();
    final elementTags = <ElementNameSelector>[];
    final source = classElement.source;
    selector.recordElementNameSelectors(elementTags);
    final bindingSynthesizer = new BindingTypeResolver(
        classElement,
        classElement.context.typeProvider,
        classElement.context,
        _errorReporter);

    final exportAs = dirSum.exportAs == ""
        ? null
        : new NavigableString(dirSum.exportAs,
            SourceRange(dirSum.exportAsOffset, dirSum.exportAs.length), source);
    final inputs = dirSum.classAnnotations.inputs
        .map((inputSum) => input(inputSum, classElement, bindingSynthesizer))
        .where((inputSum) => inputSum != null)
        .toList();
    final outputs = dirSum.classAnnotations.outputs
        .map((outputSum) => output(outputSum, classElement, bindingSynthesizer))
        .where((outputSum) => outputSum != null)
        .toList();
    final contentChildFields = dirSum.classAnnotations.contentChildFields
        .map((contentChildField) => _contentChildLinker
            .link(contentChildField, classElement, isSingular: true))
        .where((child) => child != null)
        .toList();
    final contentChildrenFields = dirSum.classAnnotations.contentChildrenFields
        .map((contentChildField) => _contentChildLinker
            .link(contentChildField, classElement, isSingular: false))
        .where((children) => children != null)
        .toList();

    for (final supertype in classElement.allSupertypes) {
      final annotatedClass =
          _directiveProvider.getAngularTopLevel(supertype.element);

      // A top-level may be a pipe which does not have inputs/outputs
      if (annotatedClass is AnnotatedClass) {
        inputs.addAll(annotatedClass.inputs.map(
            (input) => _inheritInput(input, classElement, bindingSynthesizer)));
        outputs.addAll(annotatedClass.outputs.map((output) =>
            _inheritOutput(output, classElement, bindingSynthesizer)));
        contentChildFields.addAll(annotatedClass.contentChildFields);
        contentChildrenFields.addAll(annotatedClass.contentChildrenFields);
      }
    }

    return new Directive(
      classElement,
      exportAs: exportAs,
      selector: selector,
      looksLikeTemplate: classElement.constructors.any((constructor) =>
          constructor.parameters
              .any((param) => param.type == _standardAngular.templateRef.type)),
      inputs: inputs,
      outputs: outputs,
      contentChildFields: contentChildFields,
      contentChildrenFields: contentChildrenFields,
    );
  }

  /// Partially link [FunctionalDirective] from summary and [FunctionEement].
  @override
  FunctionalDirective functionalDirective(
      SummarizedDirective dirSum, FunctionElement functionElement) {
    final selector = new SelectorParser(
            functionElement.source, dirSum.selectorOffset, dirSum.selectorStr)
        .parse();
    assert(dirSum.functionName != "");
    assert(dirSum.classAnnotations == null);
    assert(dirSum.exportAs == "");
    assert(dirSum.isComponent == false);

    return new FunctionalDirective(functionElement, selector,
        looksLikeTemplate: functionElement.parameters
            .any((param) => param.type == _standardAngular.templateRef.type));
  }

  /// Fully link an [Input] from a summary and a [ClassElement].
  Input input(SummarizedBindable inputSum, ClassElement classElement,
      BindingTypeResolver bindingSynthesizer) {
    // is this correct lookup?
    final setter =
        classElement.lookUpSetter(inputSum.propName, classElement.library);
    if (setter == null) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.INPUT_ANNOTATION_PLACEMENT_INVALID,
          inputSum.nameOffset,
          inputSum.name.length,
          [inputSum.name]);
      return null;
    }
    return new Input(
        name: inputSum.name,
        nameRange: SourceRange(inputSum.nameOffset, inputSum.name.length),
        setter: setter,
        setterType: bindingSynthesizer
            .getSetterType(setter)); // Don't think type is correct
  }

  NgContent ngContent(SummarizedNgContent ngContentSum, Source source) {
    final selector = ngContentSum.selectorStr == ""
        ? null
        : new SelectorParser(
                source, ngContentSum.selectorOffset, ngContentSum.selectorStr)
            .parse();
    return new NgContent.withSelector(
        new SourceRange(ngContentSum.offset, ngContentSum.length),
        selector,
        new SourceRange(selector?.offset, ngContentSum.selectorStr.length));
  }

  /// Fully link an [Output] from a summary and a [ClassElement].
  Output output(SummarizedBindable outputSum, ClassElement classElement,
      BindingTypeResolver bindingSynthesizer) {
    // is this correct lookup?
    final getter =
        classElement.lookUpGetter(outputSum.propName, classElement.library);
    if (getter == null) {
      return null;
    }
    return new Output(
        name: outputSum.name,
        nameRange: SourceRange(outputSum.nameOffset, outputSum.name.length),
        getter: getter,
        eventType: bindingSynthesizer.getEventType(getter, getter.name));
  }

  /// Fully link a [Pipe] from a summary and a [ClassElement].
  @override
  Pipe pipe(SummarizedPipe pipeSum, ClassElement classElement) {
    // Check if 'extends PipeTransform' exists.
    if (!classElement.type.isSubtypeOf(_standardAngular.pipeTransform.type)) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.PIPE_REQUIRES_PIPETRANSFORM,
          pipeSum.pipeNameOffset,
          pipeSum.pipeName.length);
    }

    final transformMethod =
        classElement.lookUpMethod('transform', classElement.library);
    DartType requiredArgumentType;
    DartType transformReturnType;
    final optionalArgumentTypes = <DartType>[];

    if (transformMethod == null) {
      _errorReporter.reportErrorForElement(
          AngularWarningCode.PIPE_REQUIRES_TRANSFORM_METHOD, classElement);
    } else {
      transformReturnType = transformMethod.returnType;
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
          requiredArgumentType = parameter.type;
        } else {
          optionalArgumentTypes.add(parameter.type);
        }
      }
    }
    return Pipe(
        pipeSum.pipeName,
        SourceRange(pipeSum.pipeNameOffset, pipeSum.pipeName.length),
        classElement,
        requiredArgumentType: requiredArgumentType,
        transformReturnType: transformReturnType,
        optionalArgumentTypes: optionalArgumentTypes);
  }

  List<NavigableString> _collectAttributes(ClassElement classElement) {
    final result = <NavigableString>[];
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

          result.add(new NavigableString(
              attributeName,
              SourceRange(parameter.nameOffset, parameter.nameLength),
              parameter.source));
        }
      }
    }
    return result;
  }

  Input _inheritInput(Input input, ClassElement classElement,
      BindingTypeResolver bindingSynthesizer) {
    final setter = classElement.lookUpSetter(
        input.setter.displayName, classElement.library);
    if (setter == null) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.INPUT_ANNOTATION_PLACEMENT_INVALID,
          input.nameRange.offset,
          input.nameRange.length,
          [input.name]);
      return input;
    }
    return new Input(
        name: input.name,
        nameRange: input.nameRange,
        setter: setter,
        setterType: bindingSynthesizer.getSetterType(setter));
  }

  Output _inheritOutput(Output output, ClassElement classElement,
      BindingTypeResolver bindingSynthesizer) {
    final getter =
        classElement.lookUpGetter(output.getter.name, classElement.library);
    if (getter == null) {
      // Happens when an interface with an output isn't implemented correctly.
      // This will be accompanied by a dart error, so we can just return the
      // original without transformation to prevent cascading errors.
      return output;
    }
    return new Output(
        name: output.name,
        nameRange: output.nameRange,
        getter: getter,
        eventType: bindingSynthesizer.getEventType(getter, output.name));
  }
}

/// Lazily link+resolve summaries into the resolved model.
///
/// This improves performance, especially when users use lists of directives
/// for convenience which would otherwise trigger a lot of potentially deep
/// analyses.
///
/// You cannot get linker errors from this approach because they are not
/// guaranteed to be calculated.
class LazyLinker implements TopLevelLinker {
  final EagerLinker _eagerLinker;

  LazyLinker(StandardAngular standardAngular, StandardHtml standardHtml,
      DirectiveProvider directiveProvider)
      : _eagerLinker = new EagerLinker(
            standardAngular,
            standardHtml,
            new ErrorReporter(
                new IgnoringErrorListener(), standardAngular.component.source),
            directiveProvider);

  @override
  AnnotatedClass annotatedClass(
          SummarizedClassAnnotations classSum, ClassElement classElement) =>
      _eagerLinker.annotatedClass(classSum, classElement);

  @override
  Component component(SummarizedDirective dirSum, ClassElement classElement) {
    assert(dirSum.functionName == "");
    assert(dirSum.isComponent);

    final source = classElement.source;
    final selector =
        new SelectorParser(source, dirSum.selectorOffset, dirSum.selectorStr)
            .parse();
    final elementTags = <ElementNameSelector>[];
    selector.recordElementNameSelectors(elementTags);

    final inlineNgContents = dirSum.ngContents
        .map((ngContentSum) => _eagerLinker.ngContent(ngContentSum, source))
        .toList();

    return new lazy.Component(selector, source, inlineNgContents,
        () => _eagerLinker.component(dirSum, classElement))
      ..classElement = classElement;
  }

  @override
  Directive directive(SummarizedDirective dirSum, ClassElement classElement) {
    assert(dirSum.functionName == "");
    assert(!dirSum.isComponent);

    final source = classElement.source;
    final selector =
        new SelectorParser(source, dirSum.selectorOffset, dirSum.selectorStr)
            .parse();
    final elementTags = <ElementNameSelector>[];
    selector.recordElementNameSelectors(elementTags);

    return new lazy.Directive(
        selector, () => _eagerLinker.directive(dirSum, classElement))
      ..classElement = classElement;
  }

  /// Functional directive has so few capabilities, it isn't worth lazy linking.
  ///
  /// The selector must be loaded eagerly so we can know when to bind it to a
  /// template. If it were lazy, this is where we would link it. However, for
  /// a functional directive, there would be very little linking left to do at
  /// that point.
  @override
  FunctionalDirective functionalDirective(
          SummarizedDirective dirSum, FunctionElement functionElement) =>
      _eagerLinker.functionalDirective(dirSum, functionElement);

  /// It is easy to pipes lazy because they are identified by a plain string.
  @override
  Pipe pipe(SummarizedPipe pipeSum, ClassElement classElement) => new lazy.Pipe(
      pipeSum.pipeName,
      new SourceRange(pipeSum.pipeNameOffset, pipeSum.pipeName.length),
      () => _eagerLinker.pipe(pipeSum, classElement))
    ..classElement = classElement;
}

/// Common behavior between [EagerLinker] and [LazyLinker].
///
/// To be used with the top-level linking methods [linkPipe], [likePipes],
/// [linkTopLevel], and [linkTopLevels].
abstract class TopLevelLinker {
  AnnotatedClass annotatedClass(
      SummarizedClassAnnotations classSum, ClassElement classElement);
  Component component(SummarizedDirective dirSum, ClassElement classElement);
  Directive directive(SummarizedDirective dirSum, ClassElement classElement);
  FunctionalDirective functionalDirective(
      SummarizedDirective dirSum, FunctionElement functionElement);
  Pipe pipe(SummarizedPipe pipeSum, ClassElement classElement);
}

class _ContentChildLinker {
  final DirectiveProvider _directiveProvider;
  final StandardHtml _standardHtml;
  final ErrorReporter _errorReporter;

  final htmlTypes = {'ElementRef', 'Element', 'HtmlElement'};

  _ContentChildLinker(
      this._directiveProvider, this._standardHtml, this._errorReporter);

  ContentChild link(
      SummarizedContentChildField contentChildField, ClassElement classElement,
      {bool isSingular}) {
    final nameRange = new SourceRange(
        contentChildField.nameOffset, contentChildField.nameLength);
    final typeRange = new SourceRange(
        contentChildField.typeOffset, contentChildField.typeLength);
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
              nameRange.offset,
              nameRange.length, [
            contentChildField.fieldName,
            annotationName,
            transformedType.name
          ]);
        }
        return new ContentChild(contentChildField.fieldName,
            query: new LetBoundQueriedChildType(value.toStringValue(), read),
            read: read,
            typeRange: typeRange,
            nameRange: nameRange);
      }

      // Take the type -- except, we can't validate DI symbols via `read`.
      final setterType = read == null
          ? transformedType
          : classElement.context.typeProvider.dynamicType;

      return new ContentChild(contentChildField.fieldName,
          query:
              new LetBoundQueriedChildType(value.toStringValue(), setterType),
          typeRange: typeRange,
          nameRange: nameRange,
          read: read);
    } else if (value?.toTypeValue() != null) {
      final type = value.toTypeValue();
      final referencedDirective = _directiveProvider
          .getAngularTopLevel(type.element as ClassElement) as Directive;

      QueriedChildType query;
      if (referencedDirective != null) {
        query = new DirectiveQueriedChildType(referencedDirective);
      } else if (htmlTypes.contains(type.element.name)) {
        query = new ElementQueriedChildType();
      } else if (type.element.name == 'TemplateRef') {
        query = new TemplateRefQueriedChildType();
      } else {
        _errorReporter.reportErrorForOffset(
            AngularWarningCode.UNKNOWN_CHILD_QUERY_TYPE,
            contentChildField.nameOffset,
            contentChildField.nameLength,
            [contentChildField.fieldName, annotationName]);
        return null;
      }

      _checkQueriedTypeAssignableTo(
          transformedType, read ?? type, contentChildField, annotationName);

      return new ContentChild(contentChildField.fieldName,
          query: query, read: read, typeRange: typeRange, nameRange: nameRange);
    } else {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.UNKNOWN_CHILD_QUERY_TYPE,
          contentChildField.nameOffset,
          contentChildField.nameLength,
          [contentChildField.fieldName, annotationName]);
    }
    return null;
  }

  void _checkQueriedTypeAssignableTo(
      DartType setterType,
      DartType annotatedType,
      SummarizedContentChildField field,
      String annotationName) {
    if (setterType != null && !setterType.isSupertypeOf(annotatedType)) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.INVALID_TYPE_FOR_CHILD_QUERY,
          field.typeOffset,
          field.typeLength,
          [field.fieldName, annotationName, annotatedType, setterType]);
    }
  }

  /// Get a constant [field] value off of an Object, including inheritance.
  ///
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

  /// See [_getFieldWithInheritance].
  DartType _getReadWithInheritance(DartObject value) {
    final constantVal = _getFieldWithInheritance(value, 'read');
    if (constantVal.isNull) {
      return null;
    }

    return constantVal.toTypeValue();
  }

  /// See [_getFieldWithInheritance].
  DartObject _getSelectorWithInheritance(DartObject value) =>
      _getFieldWithInheritance(value, 'selector');

  DartType _transformSetterTypeMultiple(
      DartType setterType,
      SummarizedContentChildField field,
      String annotationName,
      AnalysisContext context) {
    // construct List<Bottom>, which is a subtype of all List<T>
    final typeProvider = context.typeProvider;
    final listBottom =
        typeProvider.listType.instantiate([typeProvider.bottomType]);

    if (!setterType.isSupertypeOf(listBottom)) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.CONTENT_OR_VIEW_CHILDREN_REQUIRES_LIST,
          field.typeOffset,
          field.typeLength,
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
          SummarizedContentChildField field,
          String annotationName,
          AnalysisContext analysisContext) =>
      setterType;
}

class _ExportLinker {
  final ErrorReporter _errorReporter;

  _ExportLinker(this._errorReporter);

  Export link(SummarizedExportedIdentifier export,
      ClassElement componentClassElement, LibraryScope scope) {
    if (_hasWrongTypeOfPrefix(export, scope)) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.EXPORTS_MUST_BE_PLAIN_IDENTIFIERS,
          export.offset,
          export.length);
      return null;
    }

    final element = scope.lookup(_getIdentifier(export), null);
    if (element == componentClassElement) {
      _errorReporter.reportErrorForOffset(
          AngularWarningCode.COMPONENTS_CANT_EXPORT_THEMSELVES,
          export.offset,
          export.length);
      return null;
    }

    return new Export(export.name, export.prefix,
        new SourceRange(export.offset, export.length), element);
  }

  Identifier _getIdentifier(SummarizedExportedIdentifier export) =>
      export.prefix == ''
          ? _getSimpleIdentifier(export)
          : _getPrefixedIdentifier(export);

  SimpleIdentifier _getPrefixAsSimpleIdentifier(
          SummarizedExportedIdentifier export) =>
      astFactory.simpleIdentifier(
          new StringToken(TokenType.IDENTIFIER, export.prefix, export.offset));

  PrefixedIdentifier _getPrefixedIdentifier(
          SummarizedExportedIdentifier export) =>
      astFactory.prefixedIdentifier(
          _getPrefixAsSimpleIdentifier(export),
          new SimpleToken(
              TokenType.PERIOD, export.offset + export.prefix.length),
          _getSimpleIdentifier(export, offset: export.prefix.length + 1));

  SimpleIdentifier _getSimpleIdentifier(SummarizedExportedIdentifier export,
          {int offset: 0}) =>
      astFactory.simpleIdentifier(new StringToken(
          TokenType.IDENTIFIER, export.name, export.offset + offset));

  /// Check an export's prefix is well-formed.
  ///
  /// Only report false for known non-import-prefix prefixes, the rest get
  /// flagged by the dart analyzer already.
  bool _hasWrongTypeOfPrefix(
      SummarizedExportedIdentifier export, LibraryScope scope) {
    if (export.prefix == '') {
      return false;
    }

    final prefixElement =
        scope.lookup(_getPrefixAsSimpleIdentifier(export), null);

    return prefixElement != null && prefixElement is! PrefixElement;
  }
}

class _SubDirectiveLinker {
  final DirectiveProvider _directiveProvider;
  final ErrorReporter _errorReporter;

  _SubDirectiveLinker(this._directiveProvider, this._errorReporter);

  void link(SummarizedDirectiveUse dirUseSum, LibraryScope scope,
      List<DirectiveBase> directives) {
    final nameIdentifier = astFactory.simpleIdentifier(
        new StringToken(TokenType.IDENTIFIER, dirUseSum.name, 0));
    final prefixIdentifier = astFactory.simpleIdentifier(
        new StringToken(TokenType.IDENTIFIER, dirUseSum.prefix, 0));
    final element = scope.lookup(
        dirUseSum.prefix == ""
            ? nameIdentifier
            : astFactory.prefixedIdentifier(
                prefixIdentifier, null, nameIdentifier),
        null);

    if (element != null && element.source != null) {
      if (element is ClassElement || element is FunctionElement) {
        _addDirectiveFromElement(element, directives,
            SourceRange(dirUseSum.offset, dirUseSum.length));
        return;
      } else if (element is PropertyAccessorElement) {
        element.variable.computeConstantValue();
        final values = element.variable.constantValue?.toListValue();
        if (values != null) {
          _addDirectivesForDartObject(directives, values,
              SourceRange(dirUseSum.offset, dirUseSum.length));
          return;
        }
      }
    }

    _errorReporter.reportErrorForOffset(
        AngularWarningCode.TYPE_LITERAL_EXPECTED,
        dirUseSum.offset,
        dirUseSum.length);
  }

  void _addDirectiveFromElement(
      Element element, List<DirectiveBase> targetList, SourceRange errorRange) {
    final directive = _directiveProvider.getAngularTopLevel(element);
    if (directive != null) {
      targetList.add(directive as DirectiveBase);
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
  ///
  /// Return `true` if success, or `false` the [value] has items that don't
  /// correspond to a directive.
  void _addDirectivesForDartObject(List<DirectiveBase> directives,
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
}

class _SubPipeLinker {
  final DirectiveProvider _directiveProvider;
  final ErrorReporter _errorReporter;

  _SubPipeLinker(this._directiveProvider, this._errorReporter);

  void link(SummarizedPipesUse pipeSum, LibraryScope scope, List<Pipe> pipes) {
    final element = scope.lookup(
        astFactory.simpleIdentifier(
            new StringToken(TokenType.IDENTIFIER, pipeSum.name, 0)),
        null);

    if (element != null && element.source != null) {
      if (element is ClassElement) {
        _addPipeFromElement(
            element, pipes, SourceRange(pipeSum.offset, pipeSum.length));
        return;
      } else if (element is PropertyAccessorElement) {
        element.variable.computeConstantValue();
        final values = element.variable.constantValue?.toListValue();
        if (values != null) {
          _addPipesForDartObject(
              pipes, values, SourceRange(pipeSum.offset, pipeSum.length));
          return;
        }
      }
    }

    _errorReporter.reportErrorForOffset(
        AngularWarningCode.TYPE_LITERAL_EXPECTED,
        pipeSum.offset,
        pipeSum.length);
  }

  void _addPipeFromElement(
      ClassElement element, List<Pipe> targetList, SourceRange errorRange) {
    final pipe = _directiveProvider.getPipe(element);
    if (pipe != null) {
      targetList.add(pipe);
      return;
    } else {
      _errorReporter.reportErrorForOffset(AngularWarningCode.TYPE_IS_NOT_A_PIPE,
          errorRange.offset, errorRange.length, [element.name]);
    }
  }

  /// Walk the given [value] and add directives into [directives].
  ///
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
}
