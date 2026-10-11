"""Strict YAML loading for request files (docs/design.md 4.1). Ported unchanged from app-broker's broker/homelab/yamlstrict.py.

load(data) accepts bytes and returns only JSON-like values: dict (string keys), list, str, int, float, bool, None.
It rejects, with a StrictYAMLError:
  input over 32 KiB, bytes that are not UTF-8, a byte-order mark, CR, NUL, NEL/LS/PS line breaks,
  more than one document, directives (%YAML, %TAG), anchors, aliases, tags (including "!" and "!!str"),
  merge keys ("<<"), duplicate keys, keys that are not plain strings, numbers that are not plain decimal
  (010, 0x1F, 1_000, 1:30, 1e3, .inf), dates and timestamps, nesting deeper than 10, an empty document.

YAML 1.1 booleans (yes, no, on, off, ...) still load as booleans on purpose: the validator then rejects them with
"quote it", which is a clearer answer than silently reading them as text.

PyYAML is imported inside the functions (lazily), so importing this module never needs it.
"""
import re

MAX_BYTES = 32 * 1024
MAX_DEPTH = 10

_INT_RE = re.compile(r"-?(?:0|[1-9][0-9]{0,17})")
_FLOAT_RE = re.compile(r"-?(?:0|[1-9][0-9]{0,17})\.[0-9]{1,6}")

_TAG = "tag:yaml.org,2002:"
_loader_class = None


class StrictYAMLError(ValueError):
    """The input is not acceptable. str(error) is one line and safe to print."""


def _where(mark):
    if mark is None:
        return ""
    return " (line %d, column %d)" % (mark.line + 1, mark.column + 1)


def _fail(message, mark=None):
    raise StrictYAMLError(message + _where(mark))


def _build_loader_class():
    import yaml
    from yaml.constructor import BaseConstructor, SafeConstructor
    from yaml.events import AliasEvent
    from yaml.nodes import MappingNode, ScalarNode

    class StrictLoader(yaml.SafeLoader):
        """SafeLoader that refuses every construct the broker does not need."""

        _strict_depth = 0

        def compose_node(self, parent, index):
            if self.check_event(AliasEvent):
                _fail("aliases are not allowed", self.peek_event().start_mark)
            event = self.peek_event()
            if getattr(event, "anchor", None) is not None:
                _fail("anchors are not allowed", event.start_mark)
            if getattr(event, "tag", None) is not None:
                _fail("tags are not allowed", event.start_mark)
            self._strict_depth += 1
            try:
                if self._strict_depth > MAX_DEPTH:
                    _fail("nested too deeply", event.start_mark)
                return super().compose_node(parent, index)
            finally:
                self._strict_depth -= 1

        def construct_mapping(self, node, deep=False):
            if not isinstance(node, MappingNode):
                _fail("expected a mapping", node.start_mark)
            seen = set()
            for key_node, _value_node in node.value:
                if isinstance(key_node, ScalarNode) and key_node.tag == _TAG + "merge":
                    _fail("merge keys (<<) are not allowed", key_node.start_mark)
                if not isinstance(key_node, ScalarNode) or key_node.tag != _TAG + "str":
                    _fail("mapping keys must be plain strings; quote the key", key_node.start_mark)
                if key_node.value in seen:
                    _fail("duplicate key", key_node.start_mark)
                seen.add(key_node.value)
            # BaseConstructor on purpose: SafeConstructor.construct_mapping would first apply merge keys.
            return BaseConstructor.construct_mapping(self, node, deep=deep)

    def construct_int(loader, node):
        text = loader.construct_scalar(node)
        if not _INT_RE.fullmatch(text):
            _fail("write numbers in plain decimal, or quote the value", node.start_mark)
        return int(text)

    def construct_float(loader, node):
        text = loader.construct_scalar(node)
        if not _FLOAT_RE.fullmatch(text):
            _fail("write numbers in plain decimal, or quote the value", node.start_mark)
        return float(text)

    def construct_refused(loader, node):
        _fail("this value is read as a date, a tag or another special type; quote it", node.start_mark)

    # Only these constructors exist. Anything else (timestamp, binary, set, omap, pairs, value, unknown) is refused.
    StrictLoader.yaml_constructors = {
        _TAG + "null": SafeConstructor.construct_yaml_null,
        _TAG + "bool": SafeConstructor.construct_yaml_bool,
        _TAG + "int": construct_int,
        _TAG + "float": construct_float,
        _TAG + "str": SafeConstructor.construct_yaml_str,
        _TAG + "seq": SafeConstructor.construct_yaml_seq,
        _TAG + "map": SafeConstructor.construct_yaml_map,
        None: construct_refused,
    }
    StrictLoader.yaml_multi_constructors = {}
    return StrictLoader


def _get_loader_class():
    global _loader_class
    if _loader_class is None:
        _loader_class = _build_loader_class()
    return _loader_class


def _decode(data, max_bytes):
    if isinstance(data, str):
        try:
            data = data.encode("utf-8")
        except UnicodeEncodeError:
            _fail("input is not valid UTF-8")
    if not isinstance(data, (bytes, bytearray)):
        raise TypeError("yamlstrict.load needs bytes")
    data = bytes(data)
    if len(data) > max_bytes:
        _fail("input is larger than %d bytes" % max_bytes)
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        _fail("input is not valid UTF-8")
    if "\r" in text:
        _fail("input contains CR characters; use LF line ends")
    if "\x00" in text:
        _fail("input contains a NUL character")
    if "\ufeff" in text:
        _fail("input contains a byte-order mark")
    for bad in ("\x85", "\u2028", "\u2029"):
        if bad in text:
            _fail("input contains an unusual line-break character")
    return text


def load(data, max_bytes=MAX_BYTES):
    """Parse one strict YAML document. Raises StrictYAMLError; never returns a partially checked value."""
    text = _decode(data, max_bytes)
    import yaml
    from yaml.events import DocumentStartEvent, StreamEndEvent

    loader_class = _get_loader_class()
    loader = None
    try:
        loader = loader_class(text)                          # the reader already refuses control characters here
        loader.get_event()                                   # StreamStartEvent
        if loader.check_event(StreamEndEvent):
            _fail("the document is empty")
        event = loader.peek_event()
        if isinstance(event, DocumentStartEvent) and (event.version is not None or event.tags):
            _fail("directives are not allowed", event.start_mark)
        node = loader.compose_document()
        if not loader.check_event(StreamEndEvent):
            _fail("more than one document", loader.peek_event().start_mark)
        if node is None:
            _fail("the document is empty")
        return loader.construct_document(node)
    except StrictYAMLError:
        raise
    except yaml.MarkedYAMLError as error:
        problem = "".join(ch if 0x20 <= ord(ch) <= 0x7E and ch != "`" else "?" for ch in str(error.problem or ""))
        _fail("not valid YAML: %s" % (problem[:120] or "syntax error"), error.problem_mark)
    except yaml.YAMLError:
        _fail("not valid YAML")
    except RecursionError:
        _fail("nested too deeply")
    finally:
        if loader is not None:
            loader.dispose()


def load_mapping(data, max_bytes=MAX_BYTES):
    """load(), and the top level must be a mapping."""
    value = load(data, max_bytes)
    if not isinstance(value, dict):
        _fail("the top level must be a mapping")
    return value
