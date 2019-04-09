import 'dart:async';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/generated/source_io.dart';
import 'package:angular_analyzer_plugin/src/angular_driver.dart';
import 'package:angular_analyzer_plugin/src/model.dart';
import 'package:angular_analyzer_plugin/src/options.dart';
import 'package:angular_analyzer_plugin/src/selector/element_name_selector.dart';
import 'package:angular_analyzer_plugin/src/tuple.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import 'analyzer_base.dart';
import 'angular_base.dart';

void assertComponentReference(
    ResolvedRange resolvedRange, Component component) {
  final selector = component.selector as ElementNameSelector;
  final element = resolvedRange.navigable;
  expect(element, selector.nameElement);
  expect(resolvedRange.range.length, selector.nameElement.string.length);
}

PropertyAccessorElement assertGetter(ResolvedRange resolvedRange) {
  final element = (resolvedRange.navigable as DartElement).element
      as PropertyAccessorElement;
  expect(element.isGetter, isTrue);
  return element;
}

void assertPropertyReference(
    ResolvedRange resolvedRange, DirectiveBase directive, String name) {
  final element = resolvedRange.navigable;
  for (final input in directive.inputs) {
    if (input.name == name) {
      expect(element, input);
      return;
    }
  }
  fail('Expected input "$name", but $element found.');
}

Component getComponentByName(List<DirectiveBase> directives, String name) =>
    getDirectiveByName(directives, name) as Component;

Directive getDirectiveByName(List<DirectiveBase> directives, String name) =>
    directives.whereType<Directive>().firstWhere(
        (directive) => directive.classElement.name == name, orElse: () {
      fail('DirectiveMetadata with the class "$name" was not found.');
    });

ResolvedRange getResolvedRangeAtString(
    String code, List<ResolvedRange> ranges, String str,
    [ResolvedRangeCondition condition]) {
  final offset = code.indexOf(str);
  return ranges.firstWhere((range) {
    if (range.range.offset == offset) {
      return condition == null || condition(range);
    }
    return false;
  }, orElse: () {
    fail(
        'ResolvedRange at $offset of $str was not found in [\n${ranges.join('\n')}]');
  });
}

typedef bool ResolvedRangeCondition(ResolvedRange range);

class AngularDriverTestBase extends AngularTestBase {
  AngularDriver angularDriver;

  AngularOptions ngOptions = new AngularOptions(
      customTagNames: [
        'my-first-custom-tag',
        'my-second-custom-tag'
      ],
      customEvents: {
        'custom-event': new CustomEvent('custom-event', 'CustomEvent',
            'package:test_package/custom_event.dart', 10)
      },
      source: () {
        final mock = new MockSource();
        when(mock.fullName).thenReturn('/analysis_options.yaml');
        return mock;
      }());

  /// Assert multiple errors exist with locations, code, and arguments.
  ///
  /// For [expectedErrors], it is a List of Tuple4 (1 per error):
  ///   code segment where offset begins,
  ///   length of error highlight,
  ///   errorCode,
  ///   and optional error args - pass empty list if not needed.
  void assertMultipleErrorsExplicit(
    Source source,
    String code,
    List<Tuple4<String, int, ErrorCode, List<Object>>> expectedErrors,
  ) {
    final realErrors = errorListener.errors;
    for (final expectedError in expectedErrors) {
      final offset = code.indexOf(expectedError.item1);
      assert(offset != -1);
      final currentExpectedError = new AnalysisError(
        source,
        offset,
        expectedError.item2,
        expectedError.item3,
        expectedError.item4,
      );
      expect(
        realErrors.contains(currentExpectedError),
        true,
        reason: 'Expected error code ${expectedError.item3} never occurs at '
            'location $offset of length ${expectedError.item2}.',
      );
      expect(realErrors.length, expectedErrors.length,
          reason: 'Expected error counts do not  match.');
    }
  }

  @override
  Source newSource(String path, [String content = '']) {
    final source = super.newSource(path, content);
    // If angularDriver is null, setUp is not complete. We're loading SDK or
    // angular files, which the angularDriver doesn't need.
    angularDriver?.addFile(path);
    return source;
  }

  @override
  Future<void> setUp() async {
    super.setUp();
    angularDriver = new AngularDriver(resourceProvider, dartDriver, scheduler,
        byteStore, sourceFactory, new FileContentOverlay(), ngOptions);

    await angularDriver.getStandardAngular();
  }
}
