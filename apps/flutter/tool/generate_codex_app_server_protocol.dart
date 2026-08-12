import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const _defaultSchema =
    '../../target/codex-app-server-schemas/json/codex_app_server_protocol.schemas.json';
const _defaultOutput =
    'lib/motif/codex/protocol/generated/codex_app_server_protocol.dart';

void main(List<String> arguments) {
  final options = _Options.parse(arguments);
  final schemaFile = File(options.schema);
  if (!schemaFile.existsSync()) {
    stderr.writeln('Schema not found: ${schemaFile.path}');
    stderr.writeln(
      'Run `make codex-app-server-protocol` from the repository root.',
    );
    exitCode = 2;
    return;
  }

  final bytes = schemaFile.readAsBytesSync();
  final codexVersion = options.codexVersion ?? _codexVersion();
  final source = generateCodexProtocolSource(bytes, codexVersion: codexVersion);

  if (options.check) {
    final temp = Directory.systemTemp.createTempSync('motif-codex-protocol-');
    try {
      final candidate = File('${temp.path}/codex_app_server_protocol.dart')
        ..writeAsStringSync(source);
      _format(candidate.path);
      final output = File(options.output);
      if (!output.existsSync() ||
          output.readAsStringSync() != candidate.readAsStringSync()) {
        stderr.writeln(
          'Generated Codex protocol is out of date: ${options.output}',
        );
        exitCode = 1;
      }
    } finally {
      temp.deleteSync(recursive: true);
    }
    return;
  }

  final output = File(options.output);
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(source);
  _format(output.path);
  stdout.writeln('Generated ${output.path}');
}

/// Pure entry point used by schema fixture tests. CLI concerns such as
/// formatting, file comparison, and `codex --version` stay in [main].
String generateCodexProtocolSource(
  List<int> schemaBytes, {
  required String codexVersion,
}) {
  final document = jsonDecode(utf8.decode(schemaBytes)) as Map<String, Object?>;
  return _Generator(
    document,
    codexVersion: codexVersion,
    schemaSha256: sha256.convert(schemaBytes).toString(),
  ).generate();
}

String _codexVersion() {
  final result = Process.runSync('codex', const ['--version']);
  if (result.exitCode != 0) {
    stderr.writeln(result.stderr);
    throw StateError('Unable to run `codex --version`');
  }
  return result.stdout.toString().trim();
}

void _format(String path) {
  final result = Process.runSync(Platform.resolvedExecutable, ['format', path]);
  if (result.exitCode != 0) {
    stderr.write(result.stdout);
    stderr.write(result.stderr);
    throw StateError('dart format failed');
  }
}

final class _Options {
  const _Options({
    required this.schema,
    required this.output,
    required this.check,
    this.codexVersion,
  });

  final String schema;
  final String output;
  final bool check;
  final String? codexVersion;

  static _Options parse(List<String> arguments) {
    var schema = _defaultSchema;
    var output = _defaultOutput;
    var check = false;
    String? codexVersion;
    for (var index = 0; index < arguments.length; index++) {
      switch (arguments[index]) {
        case '--schema':
          schema = arguments[++index];
        case '--out':
          output = arguments[++index];
        case '--check':
          check = true;
        case '--codex-version':
          codexVersion = arguments[++index];
        default:
          throw ArgumentError('Unknown argument: ${arguments[index]}');
      }
    }
    return _Options(
      schema: schema,
      output: output,
      check: check,
      codexVersion: codexVersion,
    );
  }
}

final class _Generator {
  _Generator(
    this.document, {
    required this.codexVersion,
    required this.schemaSha256,
  }) {
    _loadDefinitions();
    _allocateDefinitionNames();
    _allocateVariantNames();
  }

  final Map<String, Object?> document;
  final String codexVersion;
  final String schemaSha256;
  final Map<String, Map<String, Object?>> _definitions = {};
  final Map<String, String> _names = {};
  final Map<String, List<_Variant>> _variants = {};
  final Set<String> _usedNames = {
    'CodexJson',
    'CodexJsonEncodable',
    'CodexUnknownMessage',
  };

  static const _messageUnions = {
    'ClientRequest',
    'ClientNotification',
    'ServerRequest',
    'ServerNotification',
  };

  void _loadDefinitions() {
    final root = _map(document['definitions']);
    for (final entry in root.entries) {
      if (entry.key == 'v2') {
        final v2 = _map(entry.value);
        for (final nested in v2.entries) {
          _definitions['v2/${nested.key}'] = _map(nested.value);
        }
      } else {
        _definitions[entry.key] = _map(entry.value);
      }
    }
  }

  void _allocateDefinitionNames() {
    final topNames = _definitions.keys
        .where((key) => !key.startsWith('v2/'))
        .toSet();
    for (final key in _definitions.keys.toList()..sort()) {
      final raw = key.startsWith('v2/') ? key.substring(3) : key;
      final needsNamespace = key.startsWith('v2/') && topNames.contains(raw);
      _names[key] = _unique(
        'Codex${needsNamespace ? 'V2' : ''}${_pascal(raw)}',
      );
    }
  }

  void _allocateVariantNames() {
    for (final entry in _definitions.entries) {
      final choices = _unionChoices(entry.value);
      if (choices == null || !choices.every(_isObjectSchema)) continue;
      final result = <_Variant>[];
      for (var index = 0; index < choices.length; index++) {
        final schema = choices[index];
        final title =
            schema['title'] as String? ??
            '${_names[entry.key]}Variant${index + 1}';
        final preferred = title.startsWith('Codex')
            ? _pascal(title)
            : 'Codex${_pascal(title)}';
        result.add(_Variant(_unique(preferred), schema));
      }
      _variants[entry.key] = result;
    }
  }

  String _unique(String preferred) {
    var candidate = preferred;
    var suffix = 2;
    while (!_usedNames.add(candidate)) {
      candidate = '$preferred$suffix';
      suffix++;
    }
    return candidate;
  }

  String generate() {
    final out = StringBuffer()
      ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
      ..writeln('//')
      ..writeln('// Codex version: $codexVersion')
      ..writeln('// Schema SHA-256: $schemaSha256')
      ..writeln(
        '// Command: codex app-server generate-json-schema --experimental',
      )
      ..writeln(
        '// Generator: dart run tool/generate_codex_app_server_protocol.dart',
      )
      ..writeln(
        '// ignore_for_file: dead_code, unnecessary_question_mark, unused_local_variable',
      )
      ..writeln()
      ..writeln("import 'dart:convert';")
      ..writeln()
      ..writeln(_runtime);

    for (final key in _definitions.keys.toList()..sort()) {
      _emitDefinition(out, key, _definitions[key]!);
    }
    _emitUnknownMessage(out);
    return out.toString();
  }

  void _emitDefinition(
    StringBuffer out,
    String key,
    Map<String, Object?> schema,
  ) {
    final name = _names[key]!;
    final variants = _variants[key];
    if (variants != null) {
      _emitObjectUnion(out, key, name, variants);
      return;
    }
    final enumValues = _stringEnum(schema);
    if (enumValues != null && enumValues.length > 1 && !_isNullable(schema)) {
      _emitEnum(out, name, enumValues);
      return;
    }
    final normalized = _withoutNull(schema);
    if (!_isNullable(schema) &&
        _isObjectSchema(normalized) &&
        _unionChoices(normalized) == null) {
      _emitObject(out, name, normalized);
      return;
    }
    _emitValue(out, name, schema);
  }

  void _emitEnum(StringBuffer out, String name, List<String> values) {
    final used = <String>{};
    final entries = <MapEntry<String, String>>[];
    for (final wire in values) {
      var dart = _camel(wire);
      if (dart.isEmpty || RegExp(r'^\d').hasMatch(dart)) {
        dart = 'value${_pascal(wire)}';
      }
      if (_reserved.contains(dart)) dart = '${dart}Value';
      var candidate = dart;
      var suffix = 2;
      while (!used.add(candidate)) {
        candidate = '$dart$suffix';
        suffix++;
      }
      entries.add(MapEntry(candidate, wire));
    }
    out
      ..writeln('enum $name implements CodexJsonEncodable {')
      ..writeln(
        "${entries.map((e) => '  ${e.key}(${_q(e.value)})').join(',\n')};",
      )
      ..writeln()
      ..writeln('  const $name(this.value);')
      ..writeln('  final String value;')
      ..writeln('  factory $name.fromJson(Object? json) {')
      ..writeln("    final value = CodexJson.asString(json, '$name');")
      ..writeln('    return values.firstWhere(')
      ..writeln('      (candidate) => candidate.value == value,')
      ..writeln(
        "      orElse: () => throw FormatException('Unknown $name: \$value'),",
      )
      ..writeln('    );')
      ..writeln('  }')
      ..writeln('  @override')
      ..writeln('  Object toJson() => value;')
      ..writeln('}')
      ..writeln();
  }

  void _emitValue(StringBuffer out, String name, Map<String, Object?> schema) {
    final valueType = _type(schema);
    out
      ..writeln('final class $name implements CodexJsonEncodable {')
      ..writeln('  const $name(this.value);')
      ..writeln('  final $valueType value;')
      ..writeln('  factory $name.fromJson(Object? json) =>')
      ..writeln("      $name(${_decode(schema, 'json', name)});")
      ..writeln('  @override')
      ..writeln('  Object? toJson() => CodexJson.encode(value);')
      ..writeln('}')
      ..writeln();
  }

  void _emitObject(
    StringBuffer out,
    String name,
    Map<String, Object?> schema, {
    String? extendsName,
    Map<String, String> literals = const {},
  }) {
    final properties = _map(schema['properties']);
    final required = _strings(schema['required']).toSet();
    final fields = <_Field>[];
    final usedFields = <String>{};
    for (final entry in properties.entries) {
      if (literals.containsKey(entry.key)) continue;
      var fieldName = _camel(entry.key);
      if (fieldName.isEmpty) fieldName = 'value';
      if (_reserved.contains(fieldName)) fieldName = '${fieldName}Value';
      var candidate = fieldName;
      var suffix = 2;
      while (!usedFields.add(candidate)) {
        candidate = '$fieldName$suffix';
        suffix++;
      }
      final fieldSchema = _map(entry.value);
      fields.add(
        _Field(
          wire: entry.key,
          name: candidate,
          schema: fieldSchema,
          required: required.contains(entry.key),
        ),
      );
    }

    out.writeln(
      '${extendsName == null ? 'final class' : 'final class'} $name '
      '${extendsName == null ? 'implements CodexJsonEncodable' : 'extends $extendsName'} {',
    );
    if (fields.isEmpty) {
      out.writeln('  const $name();');
    } else {
      out.writeln('  const $name({');
      for (final field in fields) {
        out.writeln(
          '    ${field.required ? 'required ' : ''}this.${field.name},',
        );
      }
      out.writeln('  });');
    }
    out.writeln();
    for (final field in fields) {
      var type = _type(field.schema);
      if (!field.required && !type.endsWith('?')) type = '$type?';
      out.writeln('  final $type ${field.name};');
    }
    if (fields.isNotEmpty) out.writeln();
    out
      ..writeln('  factory $name.fromJson(Object? json) {')
      ..writeln("    final map = CodexJson.asMap(json, '$name');");
    for (final literal in literals.entries) {
      out
        ..writeln("    if (map[${_q(literal.key)}] != ${_q(literal.value)}) {")
        ..writeln(
          "      throw FormatException('Expected ${literal.key}=${literal.value} for $name');",
        )
        ..writeln('    }');
    }
    if (fields.isEmpty) {
      out.writeln('    return const $name();');
    } else {
      out.writeln('    return $name(');
      for (final field in fields) {
        final raw = 'map[${_q(field.wire)}]';
        if (field.required) {
          out.writeln(
            '      ${field.name}: ${_decode(field.schema, raw, '$name.${field.wire}')},',
          );
        } else {
          out.writeln(
            '      ${field.name}: map.containsKey(${_q(field.wire)}) && $raw != null '
            '? ${_decode(_withoutNull(field.schema), raw, '$name.${field.wire}')} : null,',
          );
        }
      }
      out.writeln('    );');
    }
    out
      ..writeln('  }')
      ..writeln()
      ..writeln('  @override')
      ..writeln('  Map<String, Object?> toJson() => {');
    for (final literal in literals.entries) {
      out.writeln('    ${_q(literal.key)}: ${_q(literal.value)},');
    }
    for (final field in fields) {
      if (field.required) {
        out.writeln('    ${_q(field.wire)}: CodexJson.encode(${field.name}),');
      } else {
        out.writeln(
          '    if (${field.name} != null) ${_q(field.wire)}: CodexJson.encode(${field.name}),',
        );
      }
    }
    out
      ..writeln('  };')
      ..writeln('}')
      ..writeln();
  }

  void _emitObjectUnion(
    StringBuffer out,
    String key,
    String name,
    List<_Variant> variants,
  ) {
    final discriminator = _discriminator(variants);
    out
      ..writeln('sealed class $name implements CodexJsonEncodable {')
      ..writeln('  const $name();')
      ..writeln('  factory $name.fromJson(Object? json) {')
      ..writeln("    final map = CodexJson.asMap(json, '$name');");
    if (discriminator != null) {
      out.writeln('    switch (map[${_q(discriminator)}]) {');
      for (final variant in variants) {
        final literal = _literal(variant.schema, discriminator)!;
        out.writeln(
          '      case ${_q(literal)}: return ${variant.name}.fromJson(map);',
        );
      }
      if (_messageUnions.contains(key)) {
        out.writeln('      default: return CodexUnknownMessage(map);');
      } else {
        out.writeln('      default: return ${name}Unknown(map);');
      }
      out.writeln('    }');
    } else {
      for (final variant in variants) {
        out
          ..writeln('    try {')
          ..writeln('      return ${variant.name}.fromJson(map);')
          ..writeln('    } on FormatException { /* try the next variant */ }');
      }
      if (_messageUnions.contains(key)) {
        out.writeln('    return CodexUnknownMessage(map);');
      } else {
        out.writeln('    return ${name}Unknown(map);');
      }
    }
    out
      ..writeln('  }')
      ..writeln('}')
      ..writeln();

    for (final variant in variants) {
      final literals = <String, String>{};
      if (discriminator != null) {
        literals[discriminator] = _literal(variant.schema, discriminator)!;
      }
      _emitObject(
        out,
        variant.name,
        variant.schema,
        extendsName: name,
        literals: literals,
      );
    }
    if (!_messageUnions.contains(key)) {
      out
        ..writeln('final class ${name}Unknown extends $name {')
        ..writeln('  const ${name}Unknown(this.rawJson);')
        ..writeln('  final Map<String, Object?> rawJson;')
        ..writeln('  @override')
        ..writeln('  Map<String, Object?> toJson() => rawJson;')
        ..writeln('}')
        ..writeln();
    }
  }

  void _emitUnknownMessage(StringBuffer out) {
    final bases = _messageUnions
        .where(_names.containsKey)
        .map((key) => _names[key]!)
        .join(', ');
    out
      ..writeln('final class CodexUnknownMessage implements $bases {')
      ..writeln('  const CodexUnknownMessage(this.rawJson);')
      ..writeln('  final Map<String, Object?> rawJson;')
      ..writeln('  @override')
      ..writeln('  Map<String, Object?> toJson() => rawJson;')
      ..writeln('}')
      ..writeln();
  }

  String _type(Map<String, Object?> schema, {bool allowDefinition = true}) {
    if (allowDefinition) {
      final ref = schema[r'$ref'] as String?;
      if (ref != null) return _names[_refKey(ref)] ?? 'Object?';
    }
    final nullable = _isNullable(schema);
    final base = _withoutNull(schema);
    String type;
    final ref = base[r'$ref'] as String?;
    final allOf = base['allOf'];
    if (ref != null) {
      type = _names[_refKey(ref)] ?? 'Object?';
    } else if (allOf is List && allOf.length == 1) {
      type = _type(_map(allOf.single));
    } else {
      final rawType = base['type'];
      final typeName = rawType is String ? rawType : null;
      type = switch (typeName) {
        'string' => 'String',
        'integer' => 'int',
        'number' => 'num',
        'boolean' => 'bool',
        'null' => 'Null',
        'array' => 'List<${_type(_map(base['items']))}>',
        'object' => _mapType(base),
        _ => 'Object?',
      };
    }
    if (nullable && type != 'Object?' && !type.endsWith('?')) type = '$type?';
    return type;
  }

  String _mapType(Map<String, Object?> schema) {
    final additional = schema['additionalProperties'];
    if (additional is Map) return 'Map<String, ${_type(_map(additional))}>';
    return 'Map<String, Object?>';
  }

  String _decode(
    Map<String, Object?> schema,
    String expression,
    String path, {
    bool allowDefinition = true,
  }) {
    if (_isNullable(schema)) {
      final inner = _withoutNull(schema);
      return '$expression == null ? null : ${_decode(inner, expression, path, allowDefinition: allowDefinition)}';
    }
    final enumValues = _stringEnum(schema);
    if (enumValues?.length == 1) {
      return 'CodexJson.asStringLiteral($expression, ${_q(path)}, ${_q(enumValues!.single)})';
    }
    final ref = schema[r'$ref'] as String?;
    if (ref != null && allowDefinition) {
      final name = _names[_refKey(ref)];
      return name == null ? expression : '$name.fromJson($expression)';
    }
    final allOf = schema['allOf'];
    if (allOf is List && allOf.length == 1) {
      return _decode(_map(allOf.first), expression, path);
    }
    final choices = _unionChoices(schema);
    if (choices != null) return 'CodexJson.clone($expression)';
    final rawType = schema['type'];
    final typeName = rawType is String ? rawType : null;
    return switch (typeName) {
      'string' => 'CodexJson.asString($expression, ${_q(path)})',
      'integer' => 'CodexJson.asInt($expression, ${_q(path)})',
      'number' => 'CodexJson.asNum($expression, ${_q(path)})',
      'boolean' => 'CodexJson.asBool($expression, ${_q(path)})',
      'null' => 'CodexJson.asNull($expression, ${_q(path)})',
      'array' =>
        'CodexJson.asList($expression, ${_q(path)}).map((value) => '
            '${_decode(_map(schema['items']), 'value', '$path[]')}).toList(growable: false)',
      'object' => _decodeObject(schema, expression, path),
      _ => 'CodexJson.clone($expression)',
    };
  }

  String _decodeObject(
    Map<String, Object?> schema,
    String expression,
    String path,
  ) {
    final additional = schema['additionalProperties'];
    if (additional is Map) {
      return 'CodexJson.asMap($expression, ${_q(path)}).map((key, value) => '
          'MapEntry(key, ${_decode(_map(additional), 'value', '$path{}')}))';
    }
    return 'CodexJson.asMap($expression, ${_q(path)})';
  }

  String? _discriminator(List<_Variant> variants) {
    for (final candidate in const ['method', 'type']) {
      if (variants.every(
        (variant) => _literal(variant.schema, candidate) != null,
      )) {
        return candidate;
      }
    }
    return null;
  }

  String? _literal(Map<String, Object?> schema, String property) {
    final properties = _map(schema['properties']);
    final values = _stringEnum(_map(properties[property]));
    return values?.length == 1 ? values!.single : null;
  }

  static List<Map<String, Object?>>? _unionChoices(
    Map<String, Object?> schema,
  ) {
    final raw = schema['oneOf'] ?? schema['anyOf'];
    if (raw is! List || raw.isEmpty) return null;
    final choices = raw
        .map(_map)
        .where((choice) => !_isNullSchema(choice))
        .toList();
    return choices.length > 1 || (choices.length == 1 && raw.length == 1)
        ? choices
        : null;
  }

  static bool _isObjectSchema(Map<String, Object?> schema) {
    final type = schema['type'];
    return type == 'object' || (type is List && type.contains('object'));
  }

  static bool _isNullable(Map<String, Object?> schema) {
    final type = schema['type'];
    if (type is List && type.contains('null')) return true;
    for (final key in const ['oneOf', 'anyOf']) {
      final choices = schema[key];
      if (choices is List && choices.map(_map).any(_isNullSchema)) return true;
    }
    return false;
  }

  static Map<String, Object?> _withoutNull(Map<String, Object?> schema) {
    if (!_isNullable(schema)) return schema;
    final copy = Map<String, Object?>.from(schema);
    final type = copy['type'];
    if (type is List) {
      final types = type.where((value) => value != 'null').toList();
      copy['type'] = types.length == 1 ? types.single : types;
    }
    for (final key in const ['oneOf', 'anyOf']) {
      final choices = copy[key];
      if (choices is List) {
        final remaining = choices
            .map(_map)
            .where((choice) => !_isNullSchema(choice))
            .toList();
        if (remaining.length == 1) {
          copy.remove(key);
          copy.addAll(remaining.single);
        } else {
          copy[key] = remaining;
        }
      }
    }
    return copy;
  }

  static bool _isNullSchema(Map<String, Object?> schema) =>
      schema['type'] == 'null';

  static List<String>? _stringEnum(Map<String, Object?> schema) {
    final values = schema['enum'];
    if (values is! List ||
        values.isEmpty ||
        !values.every((value) => value is String)) {
      return null;
    }
    return values.cast<String>();
  }

  static String _refKey(String ref) {
    const prefix = '#/definitions/';
    if (!ref.startsWith(prefix)) return ref;
    return ref
        .substring(prefix.length)
        .replaceAll('~1', '/')
        .replaceAll('~0', '~');
  }
}

final class _Field {
  const _Field({
    required this.wire,
    required this.name,
    required this.schema,
    required this.required,
  });

  final String wire;
  final String name;
  final Map<String, Object?> schema;
  final bool required;
}

final class _Variant {
  const _Variant(this.name, this.schema);
  final String name;
  final Map<String, Object?> schema;
}

Map<String, Object?> _map(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  return const {};
}

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

String _q(String value) {
  final json = jsonEncode(value);
  final inner = json.substring(1, json.length - 1);
  return "'${inner.replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";
}

String _pascal(String value) {
  final words = value
      .split(RegExp(r'[^A-Za-z0-9]+'))
      .where((word) => word.isNotEmpty);
  final joined = words
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join();
  if (joined.isEmpty) return 'Value';
  return RegExp(r'^\d').hasMatch(joined) ? 'Value$joined' : joined;
}

String _camel(String value) {
  final pascal = _pascal(value);
  return '${pascal[0].toLowerCase()}${pascal.substring(1)}';
}

const _reserved = {
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'Function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};

const _runtime = r'''
abstract interface class CodexJsonEncodable {
  Object? toJson();
}

abstract final class CodexJson {
  static Map<String, Object?> asMap(Object? value, String path) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) return value.cast<String, Object?>();
    throw FormatException('Expected object at $path');
  }

  static List<Object?> asList(Object? value, String path) {
    if (value is List) return value.cast<Object?>();
    throw FormatException('Expected array at $path');
  }

  static String asString(Object? value, String path) {
    if (value is String) return value;
    throw FormatException('Expected string at $path');
  }

  static String asStringLiteral(
    Object? value,
    String path,
    String expected,
  ) {
    final actual = asString(value, path);
    if (actual != expected) {
      throw FormatException('Expected $expected at $path');
    }
    return actual;
  }

  static int asInt(Object? value, String path) {
    if (value is int) return value;
    throw FormatException('Expected integer at $path');
  }

  static num asNum(Object? value, String path) {
    if (value is num) return value;
    throw FormatException('Expected number at $path');
  }

  static bool asBool(Object? value, String path) {
    if (value is bool) return value;
    throw FormatException('Expected boolean at $path');
  }

  static Null asNull(Object? value, String path) {
    if (value == null) return null;
    throw FormatException('Expected null at $path');
  }

  static Object? clone(Object? value) => jsonDecode(jsonEncode(value));

  static Object? encode(Object? value) {
    if (value is CodexJsonEncodable) return value.toJson();
    if (value is List) return value.map(encode).toList(growable: false);
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), encode(item)));
    }
    return value;
  }
}
''';
