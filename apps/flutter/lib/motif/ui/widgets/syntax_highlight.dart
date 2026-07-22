import 'package:flutter/material.dart';
import 'package:highlight/highlight_core.dart';
import 'package:highlight/languages/bash.dart' as lang_bash;
import 'package:highlight/languages/cpp.dart' as lang_cpp;
import 'package:highlight/languages/cs.dart' as lang_cs;
import 'package:highlight/languages/css.dart' as lang_css;
import 'package:highlight/languages/dart.dart' as lang_dart;
import 'package:highlight/languages/diff.dart' as lang_diff;
import 'package:highlight/languages/dockerfile.dart' as lang_dockerfile;
import 'package:highlight/languages/go.dart' as lang_go;
import 'package:highlight/languages/ini.dart' as lang_ini;
import 'package:highlight/languages/java.dart' as lang_java;
import 'package:highlight/languages/javascript.dart' as lang_javascript;
import 'package:highlight/languages/json.dart' as lang_json;
import 'package:highlight/languages/kotlin.dart' as lang_kotlin;
import 'package:highlight/languages/lua.dart' as lang_lua;
import 'package:highlight/languages/makefile.dart' as lang_makefile;
import 'package:highlight/languages/markdown.dart' as lang_markdown;
import 'package:highlight/languages/php.dart' as lang_php;
import 'package:highlight/languages/python.dart' as lang_python;
import 'package:highlight/languages/ruby.dart' as lang_ruby;
import 'package:highlight/languages/rust.dart' as lang_rust;
import 'package:highlight/languages/sql.dart' as lang_sql;
import 'package:highlight/languages/swift.dart' as lang_swift;
import 'package:highlight/languages/typescript.dart' as lang_typescript;
import 'package:highlight/languages/xml.dart' as lang_xml;
import 'package:highlight/languages/yaml.dart' as lang_yaml;

import '../theme/motif_theme.dart';

abstract final class MotifSyntaxHighlight {
  static final Highlight _highlight = Highlight()
    ..registerLanguage('bash', lang_bash.bash)
    ..registerLanguage('cpp', lang_cpp.cpp)
    ..registerLanguage('cs', lang_cs.cs)
    ..registerLanguage('css', lang_css.css)
    ..registerLanguage('dart', lang_dart.dart)
    ..registerLanguage('diff', lang_diff.diff)
    ..registerLanguage('dockerfile', lang_dockerfile.dockerfile)
    ..registerLanguage('go', lang_go.go)
    ..registerLanguage('ini', lang_ini.ini)
    ..registerLanguage('java', lang_java.java)
    ..registerLanguage('javascript', lang_javascript.javascript)
    ..registerLanguage('json', lang_json.json)
    ..registerLanguage('kotlin', lang_kotlin.kotlin)
    ..registerLanguage('lua', lang_lua.lua)
    ..registerLanguage('makefile', lang_makefile.makefile)
    ..registerLanguage('markdown', lang_markdown.markdown)
    ..registerLanguage('php', lang_php.php)
    ..registerLanguage('python', lang_python.python)
    ..registerLanguage('ruby', lang_ruby.ruby)
    ..registerLanguage('rust', lang_rust.rust)
    ..registerLanguage('sql', lang_sql.sql)
    ..registerLanguage('swift', lang_swift.swift)
    ..registerLanguage('typescript', lang_typescript.typescript)
    ..registerLanguage('xml', lang_xml.xml)
    ..registerLanguage('yaml', lang_yaml.yaml);

  static const Map<String, String> _extensionLanguages = {
    'bash': 'bash',
    'c': 'cpp',
    'cc': 'cpp',
    'cpp': 'cpp',
    'cs': 'cs',
    'css': 'css',
    'cxx': 'cpp',
    'dart': 'dart',
    'diff': 'diff',
    'go': 'go',
    'h': 'cpp',
    'hpp': 'cpp',
    'htm': 'xml',
    'html': 'xml',
    'ini': 'ini',
    'java': 'java',
    'js': 'javascript',
    'json': 'json',
    'jsonc': 'json',
    'jsx': 'javascript',
    'kt': 'kotlin',
    'kts': 'kotlin',
    'lua': 'lua',
    'md': 'markdown',
    'mdx': 'markdown',
    'mjs': 'javascript',
    'patch': 'diff',
    'php': 'php',
    'py': 'python',
    'rb': 'ruby',
    'rs': 'rust',
    'sh': 'bash',
    'sql': 'sql',
    'svg': 'xml',
    'swift': 'swift',
    'ts': 'typescript',
    'tsx': 'typescript',
    'xml': 'xml',
    'yaml': 'yaml',
    'yml': 'yaml',
    'zsh': 'bash',
  };

  static String? languageForPath(String path) {
    final fileName = path.split(RegExp(r'[/\\]')).last.toLowerCase();
    if (fileName == 'dockerfile' || fileName.startsWith('dockerfile.')) {
      return 'dockerfile';
    }
    if (fileName == 'makefile' || fileName == 'gnumakefile') {
      return 'makefile';
    }
    if (fileName == '.bashrc' || fileName == '.zshrc') return 'bash';
    if (fileName == '.gitignore' || fileName == '.env') return 'ini';
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return null;
    return _extensionLanguages[fileName.substring(dot + 1)];
  }

  static TextSpan build({
    required String source,
    required String path,
    required MotifColors colors,
  }) {
    final baseStyle = MotifType.mono.copyWith(
      color: colors.textPrimary,
      height: 1.45,
    );
    final language = languageForPath(path);
    if (language == null || source.isEmpty) {
      return TextSpan(text: source, style: baseStyle);
    }
    try {
      final result = _highlight.parse(source, language: language);
      return TextSpan(
        style: baseStyle,
        children: [
          for (final node in result.nodes ?? const <Node>[])
            _spanForNode(node, colors),
        ],
      );
    } catch (_) {
      return TextSpan(text: source, style: baseStyle);
    }
  }

  static TextSpan _spanForNode(Node node, MotifColors colors) {
    final style = _styleForClass(node.className, colors);
    final value = node.value;
    if (value != null) return TextSpan(text: value, style: style);
    return TextSpan(
      style: style,
      children: [
        for (final child in node.children ?? const <Node>[])
          _spanForNode(child, colors),
      ],
    );
  }

  static TextStyle? _styleForClass(String? className, MotifColors colors) {
    if (className == null || className.isEmpty) return null;
    final classes = className.split(' ');
    if (classes.any((value) => value == 'comment' || value == 'quote')) {
      return TextStyle(color: colors.textTertiary, fontStyle: FontStyle.italic);
    }
    if (classes.any(
      (value) =>
          value == 'keyword' ||
          value == 'selector-tag' ||
          value == 'doctag' ||
          value == 'name',
    )) {
      return TextStyle(color: colors.accent, fontWeight: FontWeight.w600);
    }
    if (classes.any(
      (value) =>
          value == 'string' ||
          value == 'regexp' ||
          value == 'addition' ||
          value == 'attribute',
    )) {
      return TextStyle(color: colors.success);
    }
    if (classes.any(
      (value) =>
          value == 'number' ||
          value == 'literal' ||
          value == 'symbol' ||
          value == 'bullet',
    )) {
      return TextStyle(color: colors.warning);
    }
    if (classes.any(
      (value) => value == 'built_in' || value == 'type' || value == 'class',
    )) {
      return TextStyle(color: colors.accent);
    }
    if (classes.any(
      (value) => value == 'title' || value == 'function' || value == 'section',
    )) {
      return TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w600);
    }
    if (classes.any(
      (value) =>
          value == 'meta' || value == 'deletion' || value == 'template-tag',
    )) {
      return TextStyle(color: colors.danger);
    }
    if (classes.any(
      (value) =>
          value == 'attr' ||
          value == 'variable' ||
          value == 'params' ||
          value == 'selector-class',
    )) {
      return TextStyle(color: colors.warning);
    }
    return null;
  }
}
