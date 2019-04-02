import 'dart:collection';

/// A constraint system for suggesting full HTML tags from a [Selector].
///
/// Where possible it is good to be able to suggest a fully completed html tag
/// to match a selector. This has a few challenges: the selector may match
/// multiple things, it may not include any tag name to go off of at all. It may
/// lend itself to infinite suggestions (such as matching a regex), and parts
/// of its selector may cancel other parts out leading to invalid suggestions
/// (such as [prop=this][prop=thistoo]), especially in the presence of heavy
/// booleans.
///
/// This doesn't track :not, so it may still suggest invalid things, but in
/// general the goal of this class is that its an empty shell which tracks
/// conflicting information.
///
/// Each selector takes in the current round of suggestions in
/// [refineTagSuggestions], and may return more suggestions than it got
/// originally (as in OR). At the end, all valid selectors can be checked for
/// validity.
///
/// Selector.suggestTags() handles creating a seed HtmlTagForSelector and
/// stripping invalid suggestions at the end, potentially resulting in none.
class HtmlTagForSelector {
  String _name;
  Map<String, String> _attributes = {};
  bool _isValid = true;
  Set<String> _classes = {};

  bool get isValid => _name != null && _isValid && _classAttrValid;

  String get name => _name;

  set name(String name) {
    if (_name != null && _name != name) {
      _isValid = false;
    } else {
      _name = name;
    }
  }

  bool get _classAttrValid => _classes.isEmpty || _attributes["class"] == null
      ? true
      : _classes.length == 1 && _classes.first == _attributes["class"];

  void addClass(String classname) {
    _classes.add(classname);
  }

  HtmlTagForSelector clone() => new HtmlTagForSelector()
    ..name = _name
    .._attributes = (<String, String>{}..addAll(_attributes))
    .._isValid = _isValid
    .._classes = new HashSet<String>.from(_classes);

  void setAttribute(String name, {String value}) {
    if (_attributes.containsKey(name)) {
      if (value != null) {
        if (_attributes[name] != null && _attributes[name] != value) {
          _isValid = false;
        } else {
          _attributes[name] = value;
        }
      }
    } else {
      _attributes[name] = value;
    }
  }

  @override
  String toString() {
    final keepClassAttr = _classes.isEmpty;

    final attrStrs = <String>[];
    _attributes.forEach((k, v) {
      // in the case of [class].myclass don't create multiple class attrs
      if (k != "class" || keepClassAttr) {
        attrStrs.add(v == null ? k : '$k="$v"');
      }
    });

    if (_classes.isNotEmpty) {
      final classesList = (<String>[]
            ..addAll(_classes)
            ..sort())
          .join(' ');
      attrStrs.add('class="$classesList"');
    }

    attrStrs.sort();

    return (['<$_name']..addAll(attrStrs)).join(' ');
  }
}
