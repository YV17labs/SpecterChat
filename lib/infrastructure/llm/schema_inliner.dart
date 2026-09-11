/// Inlines a tool schema's local `$ref`s before it goes to the model.
///
/// MCP servers may describe nested types through `$defs` + `$ref` (rmcp,
/// pydantic, older zod), which is valid JSON Schema — but several model
/// runtimes read a parameter's `type` straight off the property and never
/// follow a reference. Ollama's Qwen3 parser is one: a `region` declared as
/// `anyOf: [{$ref: RegionDto}, {type: null}]` reaches the tool as a string.
/// Presenting tools to the provider is the host's job, so the host inlines.
///
/// Only local pointers (`#/$defs/<name>`, `#/definitions/<name>`) are
/// resolved; anything else is left untouched. Keywords sitting beside a
/// `$ref` (`default`, `description`) are kept and win over the definition's.
/// A recursive definition cannot be inlined: its `$ref` is left in place and
/// the definitions block is then kept so the pointer still resolves.
Map<String, dynamic> inlineLocalRefs(Map<String, dynamic> schema) {
  const containers = [r'$defs', 'definitions'];
  final defs = <String, Map<dynamic, dynamic>>{};
  for (final container in containers) {
    final block = schema[container];
    if (block is! Map) continue;
    for (final entry in block.entries) {
      final def = entry.value;
      if (def is Map) defs['#/$container/${entry.key}'] = def;
    }
  }
  if (defs.isEmpty) return schema;

  var unresolved = false;

  dynamic walk(dynamic node, Set<String> stack) {
    if (node is List) return [for (final item in node) walk(item, stack)];
    if (node is! Map) return node;

    final map = node.cast<String, dynamic>();
    final ref = map[r'$ref'];
    final def = defs[ref];
    if (def != null && !stack.contains(ref)) {
      final siblings = {...map}..remove(r'$ref');
      return walk({...def, ...siblings}, {...stack, ref as String});
    }
    if (def != null) unresolved = true; // recursive: already on the stack
    return {for (final e in map.entries) e.key: walk(e.value, stack)};
  }

  final body = {...schema}..removeWhere((k, _) => containers.contains(k));
  final out = walk(body, const {}) as Map<String, dynamic>;
  if (unresolved) {
    for (final container in containers) {
      if (schema.containsKey(container)) out[container] = schema[container];
    }
  }
  return out;
}
