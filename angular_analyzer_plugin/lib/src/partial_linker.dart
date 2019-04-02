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
import 'package:angular_analyzer_plugin/src/element_resolver.dart';
import 'package:angular_analyzer_plugin/src/ignoring_error_listener.dart';
import 'package:angular_analyzer_plugin/src/model.dart';
import 'package:angular_analyzer_plugin/src/model/lazy/component.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/lazy/directive.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/lazy/pipe.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/syntactic/ng_content.dart';
import 'package:angular_analyzer_plugin/src/selector.dart';
import 'package:angular_analyzer_plugin/src/selector/element_name_selector.dart';
import 'package:angular_analyzer_plugin/src/standard_components.dart';

import 'summary/idl.dart';

/// Low-level linking functionality that does not require the dart element
/// model.
///
/// Some of this produces syntactic concepts, and other parts of this generate
/// partially resolved instances of the resolved model. Once the resolved model
/// is statically guaranteed to have all fields initialized, this will be split
/// up. Resolution will be mixed into the linking process, and syntactic
/// concepts will have their own linker.
class PartialFromSummaryOnly {
  ContentChildField contentChildField(SummarizedContentChildField fieldSum) =>
      new ContentChildField(fieldSum.fieldName,
          nameRange: new SourceRange(fieldSum.nameOffset, fieldSum.nameLength),
          typeRange: new SourceRange(fieldSum.typeOffset, fieldSum.typeLength));

  DirectiveReference directiveReference(SummarizedDirectiveUse dirUseSum) =>
      new DirectiveReference(dirUseSum.name, dirUseSum.prefix,
          new SourceRange(dirUseSum.offset, dirUseSum.length));

  ExportedIdentifier exportedIdentifier(SummarizedExportedIdentifier export) =>
      new ExportedIdentifier(
          export.name, new SourceRange(export.offset, export.length),
          prefix: export.prefix);

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

  PipeReference pipeReference(SummarizedPipesUse pipeUse) => new PipeReference(
      pipeUse.name, new SourceRange(pipeUse.offset, pipeUse.length),
      prefix: pipeUse.prefix);
}

/// Generate partially resolved model instances from summary and the Dart
/// [Element] model.
///
/// This exists for backwards compatibility. Ideally, the resolver would be able
/// to operate on the summaries or syntactic model directly. At the moment,
/// however, it requires partially-resolved instances of the resolved model.
/// This class sets that data up, but in the future, the two stages will be
/// blended into one stage of linking.
class PartialLinker extends PartialFromSummaryOnly implements TopLevelLinker {
  final StandardAngular _standardAngular;
  final ErrorReporter _errorReporter;

  PartialLinker(this._standardAngular, this._errorReporter);

  /// Fully link an [AngularAnnotatedClass] from a summary and a [ClassElement].
  @override
  AngularAnnotatedClass annotatedClass(
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
        .map(contentChildField)
        .where((child) => child != null)
        .toList();
    final contentChildrenFields = classSum.contentChildrenFields
        .map(contentChildField)
        .where((children) => children != null)
        .toList();

    return new AngularAnnotatedClass(classElement,
        inputs: inputs,
        outputs: outputs,
        contentChildFields: contentChildFields,
        contentChildrenFields: contentChildrenFields);
  }

  /// Partially link a [Component] from a summary and a [ClassElement].
  @override
  Component component(SummarizedDirective dirSum, ClassElement classElement) {
    assert(dirSum.isComponent);
    return directive(dirSum, classElement) as Component;
  }

  /// Partially link an [AbstractClassDirective] from a summary and a
  /// [ClassElement].
  @override
  AbstractClassDirective directive(
      SummarizedDirective dirSum, ClassElement classElement) {
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

    final ngContents = dirSum.ngContents
        .map((ngContentSum) => ngContent(ngContentSum, source))
        .toList();
    final exportAs = dirSum.exportAs == ""
        ? null
        : new AngularElementImpl(dirSum.exportAs, dirSum.exportAsOffset,
            dirSum.exportAs.length, source);
    final inputs = dirSum.classAnnotations.inputs
        .map((inputSum) => input(inputSum, classElement, bindingSynthesizer))
        .where((inputSum) => inputSum != null)
        .toList();
    final outputs = dirSum.classAnnotations.outputs
        .map((outputSum) => output(outputSum, classElement, bindingSynthesizer))
        .where((outputSum) => outputSum != null)
        .toList();
    final contentChildFields = dirSum.classAnnotations.contentChildFields
        .map(contentChildField)
        .where((child) => child != null)
        .toList();
    final contentChildrenFields = dirSum.classAnnotations.contentChildrenFields
        .map(contentChildField)
        .where((children) => children != null)
        .toList();

    if (!dirSum.isComponent) {
      return new Directive(classElement,
          exportAs: exportAs,
          selector: selector,
          inputs: inputs,
          outputs: outputs,
          elementTags: elementTags,
          contentChildFields: contentChildFields,
          contentChildrenFields: contentChildrenFields);
    }

    final exports = dirSum.exports.map(exportedIdentifier).toList();
    final pipeRefs = dirSum.pipesUse.map(pipeReference).toList();
    final component = new Component(classElement,
        exportAs: exportAs,
        selector: selector,
        inputs: inputs,
        outputs: outputs,
        isHtml: false,
        ngContents: ngContents,
        elementTags: elementTags,
        contentChildFields: contentChildFields,
        contentChildrenFields: contentChildrenFields);
    final subDirectives = dirSum.subdirectives.map(directiveReference).toList();
    Source templateUriSource;
    SourceRange templateUrlRange;
    if (dirSum.templateUrl != '') {
      templateUriSource = classElement.context.sourceFactory
          .resolveUri(classElement.library.source, dirSum.templateUrl);
      templateUrlRange =
          new SourceRange(dirSum.templateUrlOffset, dirSum.templateUrlLength);
      if (!templateUriSource.exists()) {
        _errorReporter.reportErrorForOffset(
          AngularWarningCode.REFERENCED_HTML_FILE_DOESNT_EXIST,
          dirSum.templateUrlOffset,
          dirSum.templateUrlLength,
        );
      }
    }
    component.view = new View(classElement, component, [], [],
        templateText: dirSum.templateText,
        templateOffset: dirSum.templateOffset,
        templateUriSource: templateUriSource,
        templateUrlRange: templateUrlRange,
        directivesStrategy: dirSum.usesArrayOfDirectiveReferencesStrategy
            ? new ArrayOfDirectiveReferencesStrategy(subDirectives)
            : new UseConstValueStrategy(
                classElement,
                _standardAngular,
                new SourceRange(dirSum.constDirectiveStrategyOffset,
                    dirSum.constDirectiveStrategyLength)),
        exports: exports,
        pipeReferences: pipeRefs);
    return component;
  }

  /// Partially link a [FunctionalDirective] from a summary and a
  /// [FunctionEement].
  @override
  FunctionalDirective functionalDirective(
      SummarizedDirective dirSum, FunctionElement functionElement) {
    final selector = new SelectorParser(
            functionElement.source, dirSum.selectorOffset, dirSum.selectorStr)
        .parse();
    final elementTags = <ElementNameSelector>[];
    selector.recordElementNameSelectors(elementTags);
    assert(dirSum.functionName != "");
    // TODO lazy functional directives?
    assert(dirSum.classAnnotations == null);
    assert(dirSum.exportAs == "");
    assert(dirSum.isComponent == false);

    return new FunctionalDirective(functionElement, selector, elementTags);
  }

  /// Fully link an [InputElement] from a summary and a [ClassElement].
  InputElement input(SummarizedBindable inputSum, ClassElement classElement,
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
    return new InputElement(
        inputSum.name,
        inputSum.nameOffset,
        inputSum.name.length,
        classElement.source,
        setter,
        new SourceRange(inputSum.propNameOffset, inputSum.propName.length),
        bindingSynthesizer
            .getSetterType(setter)); // Don't think type is correct
  }

  /// Fully link an [OutputElement] from a summary and a [ClassElement].
  OutputElement output(SummarizedBindable outputSum, ClassElement classElement,
      BindingTypeResolver bindingSynthesizer) {
    // is this correct lookup?
    final getter =
        classElement.lookUpGetter(outputSum.propName, classElement.library);
    if (getter == null) {
      return null;
    }
    return new OutputElement(
        outputSum.name,
        outputSum.nameOffset,
        outputSum.name.length,
        classElement.source,
        getter,
        new SourceRange(outputSum.propNameOffset, outputSum.propName.length),
        bindingSynthesizer.getEventType(getter, getter.name));
  }

  /// Fully link a [Pipe] from a summary and a [ClassElement].
  @override
  Pipe pipe(SummarizedPipe pipeSum, ClassElement classElement) =>
      new Pipe(pipeSum.pipeName, pipeSum.pipeNameOffset, classElement,
          isPure: pipeSum.isPure);
}
