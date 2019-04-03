import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/generated/source.dart' show Source;
import 'package:angular_analyzer_plugin/src/model.dart' hide Component;
import 'package:angular_analyzer_plugin/src/model.dart' as resolved;
import 'package:angular_analyzer_plugin/src/model/lazy/view.dart' as lazy;
import 'package:angular_analyzer_plugin/src/model/syntactic/ng_content.dart';
import 'package:angular_analyzer_plugin/src/selector.dart';
import 'package:angular_analyzer_plugin/src/selector/element_name_selector.dart';

class Component implements resolved.Component {
  @override
  final Selector selector;
  @override
  final String name;

  resolved.Component Function() linkFn;

  @override
  View view;

  @override
  ClassElement classElement;

  resolved.Component _linkedComponent;

  List<NgContent> _inlineNgContents;

  Component(this.selector, this.name, Source source, this._inlineNgContents,
      this.linkFn) {
    view = new lazy.View(this);
  }

  @override
  List<AngularElement> get attributes => load().attributes;

  @override
  List<ContentChildField> get contentChildFields => load().contentChildFields;

  @override
  set contentChildFields(List<ContentChildField> _contentChildFields) {
    throw UnsupportedError(
        'lazy components should not change [contentChildFields]');
  }

  @override
  List<ContentChild> get contentChildren => load().contentChildren;

  @override
  List<ContentChildField> get contentChildrenFields =>
      load().contentChildrenFields;

  @override
  set contentChildrenFields(List<ContentChildField> _contentChildrenFields) {
    throw UnsupportedError(
        'lazy components should not change [contentChildrenFields]');
  }

  @override
  List<ContentChild> get contentChilds => load().contentChilds;

  @override
  List<ElementNameSelector> get elementTags {
    final elementTags = <ElementNameSelector>[];
    selector.recordElementNameSelectors(elementTags);
    return elementTags;
  }

  @override
  AngularElement get exportAs => load().exportAs;

  @override
  List<ExportedIdentifier> get exports => load().exports;

  @override
  List<InputElement> get inputs => load().inputs;

  @override
  bool get isHtml => load().isHtml;

  bool get isLinked => _linkedComponent != null;

  @override
  bool get looksLikeTemplate => load().looksLikeTemplate;

  @override
  set looksLikeTemplate(bool _looksLikeTemplate) {
    throw UnsupportedError(
        'lazy components should not change [looksLikeTemplate]');
  }

  @override
  List<NgContent> get ngContents =>
      _inlineNgContents == null ? load().ngContents : _inlineNgContents;

  @override
  List<OutputElement> get outputs => load().outputs;

  @override
  Source get source => classElement.source;

  @override
  bool operator ==(Object other) =>
      other is Component && other.source == source && other.name == name;

  resolved.Component load() => _linkedComponent ??= linkFn();
}
