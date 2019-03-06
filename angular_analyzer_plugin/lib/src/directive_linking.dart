import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/generated/source.dart' show Source;
import 'package:angular_analyzer_plugin/src/element_resolver.dart';
import 'package:angular_analyzer_plugin/src/ignoring_error_listener.dart';
import 'package:angular_analyzer_plugin/src/model.dart';
import 'package:angular_analyzer_plugin/src/model.dart';
import 'package:angular_analyzer_plugin/src/model/lazy/component.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/lazy/directive.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/lazy/pipe.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/syntactic/ng_content.dart';
import 'package:angular_analyzer_plugin/src/partial_linker.dart';
import 'package:angular_analyzer_plugin/src/selector.dart';
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

/// Link [AngularTopLevel] with the specified [Linker] from its summary &
/// element.
AngularTopLevel linkTopLevel(
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

/// Link [AngularTopLevel]s with the specified [Linker] from a summary &
/// compilation unit.
List<AngularTopLevel> linkTopLevels(UnlinkedDartSummary unlinked,
        CompilationUnitElement compilationUnitElement, TopLevelLinker linker) =>
    unlinked.directiveSummaries.map<AngularTopLevel>((sum) {
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

/// In order to link, we need a [DirectiveProvider] to be able to look up
/// angular information from source paths and the Dart [Element] model.
abstract class DirectiveProvider {
  AngularTopLevel getAngularTopLevel(Element element);
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
  final PartialLinker _partialLinker;
  final ResolvePartialModel _resolvePartialModel;

  EagerLinker(StandardAngular standardAngular, StandardHtml standardHtml,
      ErrorReporter errorReporter, DirectiveProvider directiveProvider)
      : _partialLinker = new PartialLinker(standardAngular, errorReporter),
        _resolvePartialModel = new ResolvePartialModel(
            standardAngular, standardHtml, errorReporter, directiveProvider);

  @override
  AngularAnnotatedClass annotatedClass(
          SummarizedClassAnnotations classSum, ClassElement classElement) =>
      _partialLinker.annotatedClass(classSum, classElement);

  @override
  Component component(SummarizedDirective dirSum, ClassElement classElement) {
    final partial = _partialLinker.directive(dirSum, classElement) as Component;

    return _resolvePartialModel.component(partial, classElement);
  }

  @override
  AbstractClassDirective directive(
          SummarizedDirective dirSum, ClassElement classElement) =>
      _resolvePartialModel
          .directive(_partialLinker.directive(dirSum, classElement));

  @override
  FunctionalDirective functionalDirective(
          SummarizedDirective dirSum, FunctionElement functionElement) =>
      _resolvePartialModel.functionalDirective(
          _partialLinker.functionalDirective(dirSum, functionElement));

  NgContent ngContent(SummarizedNgContent ngContentSum, Source source) =>
      _partialLinker.ngContent(ngContentSum, source);

  @override
  Pipe pipe(SummarizedPipe pipeSum, ClassElement classElement) =>
      _resolvePartialModel.pipe(
          _partialLinker.pipe(pipeSum, classElement), classElement);
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
  final PartialFromSummaryOnly _partialFromSummaryOnly =
      new PartialFromSummaryOnly();
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
  AngularAnnotatedClass annotatedClass(
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
        .map((ngContentSum) =>
            _partialFromSummaryOnly.ngContent(ngContentSum, source))
        .toList();

    return new lazy.Component(
        selector,
        dirSum.classAnnotations.className,
        source,
        inlineNgContents,
        () => _eagerLinker.component(dirSum, classElement))
      ..classElement = classElement;
  }

  @override
  AbstractClassDirective directive(
      SummarizedDirective dirSum, ClassElement classElement) {
    assert(dirSum.functionName == "");
    assert(!dirSum.isComponent);

    final source = classElement.source;
    final selector =
        new SelectorParser(source, dirSum.selectorOffset, dirSum.selectorStr)
            .parse();
    final elementTags = <ElementNameSelector>[];
    selector.recordElementNameSelectors(elementTags);

    return new lazy.Directive(selector, dirSum.classAnnotations.className,
        source, () => _eagerLinker.directive(dirSum, classElement) as Directive)
      ..classElement = classElement;
  }

  /// Functional directive is not lazy it has so few capabilities, it isn't
  /// worth lazy linking.
  ///
  /// The selector must be loaded eagerly so we can know when to bind it to a
  /// template. If it were lazy, this is where we would link it. However, for
  /// a functional directive, there would be very little linking left to do at
  /// that point.
  @override
  FunctionalDirective functionalDirective(
          SummarizedDirective dirSum, FunctionElement functionElement) =>
      _eagerLinker.functionalDirective(dirSum, functionElement);

  /// Pipes likely do not need to be lazy, however, it is easy to make them
  /// lazy because they are identified by a their name, a plain string.
  @override
  Pipe pipe(SummarizedPipe pipeSum, ClassElement classElement) => new lazy.Pipe(
      pipeSum.pipeName,
      pipeSum.pipeNameOffset,
      () => _eagerLinker.pipe(pipeSum, classElement))
    ..classElement = classElement;
}

/// Common behavior between [EagerLinker] and [LazyLinker], to be used with the
/// top-level linking methods [linkPipe], [likePipes], [linkTopLevel],
/// and [linkTopLevels].
abstract class TopLevelLinker {
  AngularAnnotatedClass annotatedClass(
      SummarizedClassAnnotations classSum, ClassElement classElement);
  Component component(SummarizedDirective dirSum, ClassElement classElement);
  AbstractClassDirective directive(
      SummarizedDirective dirSum, ClassElement classElement);
  FunctionalDirective functionalDirective(
      SummarizedDirective dirSum, FunctionElement functionElement);
  Pipe pipe(SummarizedPipe pipeSum, ClassElement classElement);
}
