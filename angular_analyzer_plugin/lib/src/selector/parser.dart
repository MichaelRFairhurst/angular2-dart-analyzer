import 'package:analyzer/src/generated/source.dart';
import 'package:angular_analyzer_plugin/src/selector/and_selector.dart';
import 'package:angular_analyzer_plugin/src/selector/attribute_contains_selector.dart';
import 'package:angular_analyzer_plugin/src/selector/attribute_selector.dart';
import 'package:angular_analyzer_plugin/src/selector/attribute_starts_with_selector.dart';
import 'package:angular_analyzer_plugin/src/selector/attribute_value_regex_selector.dart';
import 'package:angular_analyzer_plugin/src/selector/class_selector.dart';
import 'package:angular_analyzer_plugin/src/selector/contains_selector.dart';
import 'package:angular_analyzer_plugin/src/selector/element_name_selector.dart';
import 'package:angular_analyzer_plugin/src/selector/name.dart';
import 'package:angular_analyzer_plugin/src/selector/not_selector.dart';
import 'package:angular_analyzer_plugin/src/selector/or_selector.dart';
import 'package:angular_analyzer_plugin/src/selector/parse_error.dart';
import 'package:angular_analyzer_plugin/src/selector/selector.dart';
import 'package:angular_analyzer_plugin/src/selector/tokenizer.dart';

/// A parser for CSS [Selector]s.
class SelectorParser with ReportParseErrors {
  Tokenizer tokenizer;
  int lastOffset = 0;
  final int fileOffset;
  @override
  final String str;
  final Source source;
  SelectorParser(this.source, this.fileOffset, this.str);

  /// Try to parse a [Selector], throwing [SelectorParseError] on error.
  ///
  /// Also may return [null] if the provided string is null.
  Selector parse() {
    if (str == null) {
      return null;
    }
    tokenizer = new Tokenizer(str, fileOffset);
    final selector = _parseNested();

    // Report dangling end tokens
    if (tokenizer.current != null) {
      unexpected(tokenizer.current.lexeme, tokenizer.current.offset);
    }

    return selector
      ..originalString = str
      ..offset = fileOffset;
  }

  Selector _andSelectors(List<Selector> selectors) {
    if (selectors.length == 1) {
      return selectors[0];
    }
    return new AndSelector(selectors);
  }

  Selector _parseNested() {
    final selectors = <Selector>[];
    while (tokenizer.current != null) {
      if (tokenizer.current.type == TokenType.NotEnd) {
        // don't advance, just know we're at the end of this.
        break;
      }

      if (tokenizer.current.type == TokenType.NotStart) {
        selectors.add(_parseNotSelector());
      } else if (tokenizer.current.type == TokenType.Tag) {
        final nameOffset = tokenizer.current.offset;
        final name = tokenizer.current.lexeme;
        selectors.add(new ElementNameSelector(new SelectorName(
            name, new SourceRange(nameOffset, name.length), source)));
        tokenizer.advance();
      } else if (tokenizer.current.type == TokenType.Class) {
        final nameOffset = tokenizer.current.offset + 1;
        final name = tokenizer.current.lexeme;
        selectors.add(new ClassSelector(new SelectorName(
            name, new SourceRange(nameOffset, name.length), source)));
        tokenizer.advance();
      } else if (tokenizer.current.type == TokenType.Attribute) {
        final nameOffset = tokenizer.current.offset + '['.length;
        final operator = tokenizer.currentOperator;
        final value = tokenizer.currentValue;

        if (operator != null && value.lexeme.isEmpty) {
          expected('a value after ${operator.lexeme}',
              actual: ']', offset: tokenizer.current.endOffset - 1);
        }

        var name = tokenizer.current.lexeme;
        tokenizer.advance();

        if (name == '*' &&
            value != null &&
            value.lexeme.startsWith('/') &&
            value.lexeme.endsWith('/')) {
          if (operator?.lexeme != '=') {
            unexpected(operator.lexeme, nameOffset + name.length);
          }
          final valueOffset = nameOffset + name.length + '='.length;
          final regex = value.lexeme.substring(1, value.lexeme.length - 1);
          selectors.add(new AttributeValueRegexSelector(new SelectorName(
              regex, new SourceRange(valueOffset, regex.length), source)));
          continue;
        } else if (operator?.lexeme == '*=') {
          name = name.replaceAll('*', '');
          selectors.add(new AttributeContainsSelector(
              new SelectorName(
                  name, new SourceRange(nameOffset, name.length), source),
              value.lexeme));
          continue;
        } else if (operator?.lexeme == '^=') {
          selectors.add(new AttributeStartsWithSelector(
              new SelectorName(
                  name, new SourceRange(nameOffset, name.length), source),
              value.lexeme));
          continue;
        }

        selectors.add(new AttributeSelector(
            new SelectorName(
                name, SourceRange(nameOffset, name.length), source),
            value?.lexeme));
      } else if (tokenizer.current.type == TokenType.Comma) {
        tokenizer.advance();
        final rhs = _parseNested();
        if (rhs is OrSelector) {
          // flatten "a, b, c, d" from (a, (b, (c, d))) into (a, b, c, d)
          return new OrSelector(
              <Selector>[_andSelectors(selectors)]..addAll(rhs.selectors));
        } else {
          return new OrSelector(<Selector>[_andSelectors(selectors), rhs]);
        }
      } else if (tokenizer.current.type == TokenType.Contains) {
        selectors
            .add(new ContainsSelector(tokenizer.currentContainsString.lexeme));
        tokenizer.advance();
      } else {
        break;
      }
    }
    // final result
    return _andSelectors(selectors);
  }

  NotSelector _parseNotSelector() {
    tokenizer.advance();
    final condition = _parseNested();
    if (tokenizer.current.type != TokenType.NotEnd) {
      unexpected(
          tokenizer.current.lexeme, tokenizer?.current?.offset ?? lastOffset);
    }
    tokenizer.advance();
    return new NotSelector(condition);
  }
}
