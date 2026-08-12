import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_thread_catalog.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';

void main() {
  test('global state preserves local hierarchy and deduplicates pinned', () {
    final global = CodexGlobalStateData.tryParse(
      jsonEncode({
        'local-projects': {
          'p1': {
            'id': 'p1',
            'name': 'Motif',
            'rootPaths': ['/work/motif'],
            'updatedAt': '2026-08-10T12:00:00Z',
          },
          'empty': {
            'id': 'empty',
            'name': 'Empty project',
            'rootPaths': ['/work/empty'],
            'updatedAt': '2026-08-11T12:00:00Z',
          },
        },
        'remote-projects': [
          {'id': 'remote', 'name': 'Remote'},
        ],
        'project-order': ['remote', 'empty', 'p1'],
        'pinned-thread-ids': ['t2', 'missing'],
        'projectless-thread-ids': ['t3'],
        'thread-project-assignments': {
          't1': {
            'projectKind': 'local',
            'projectId': 'p1',
            'cwd': '/work/motif',
          },
          't2': {
            'projectKind': 'local',
            'projectId': 'p1',
            'cwd': '/work/motif',
          },
          't3': {
            'projectKind': 'local',
            'projectId': 'p1',
            'cwd': '/work/motif',
          },
          'remote-thread': {'projectKind': 'remote', 'projectId': 'remote'},
        },
        'sidebar-project-thread-orders': {
          'p1': {
            'threadIds': ['t2', 't1'],
          },
        },
        'selected-project': {'type': 'local', 'projectId': 'p1'},
      }),
    );
    expect(global, isNotNull);

    final snapshot = buildCodexCatalog([
      thread('t1', cwd: '/work/motif', updatedAt: 10),
      thread('t2', cwd: '/work/motif', updatedAt: 20),
      thread('t3', cwd: '/work/motif', updatedAt: 30),
      thread('t4', cwd: '/work/other', updatedAt: 40),
    ], global);

    expect(snapshot.usesGlobalState, isTrue);
    expect(snapshot.projects.map((group) => group.project.id), ['empty', 'p1']);
    expect(snapshot.projects.first.threads, isEmpty);
    expect(snapshot.projects.last.threads.map((thread) => thread.id), ['t1']);
    expect(snapshot.pinnedThreads.map((thread) => thread.id), ['t2']);
    expect(snapshot.projectlessThreads.map((thread) => thread.id), [
      't4',
      't3',
    ]);
    expect(snapshot.projectNameForThread('t2'), 'Motif');
    expect(snapshot.projectNameForThread('t3'), isNull);
    expect(snapshot.selectedProjectId, 'p1');
  });

  test('missing global state falls back to exact cwd groups', () {
    final snapshot = buildCodexCatalog([
      thread('a', cwd: '/one/shared', updatedAt: 10),
      thread('b', cwd: '/two/shared', updatedAt: 20),
      thread('c', cwd: '', updatedAt: 30),
      thread('ephemeral', cwd: '/one/shared', ephemeral: true),
    ], null);

    expect(snapshot.usesGlobalState, isFalse);
    expect(snapshot.projects, hasLength(2));
    expect(snapshot.projects.map((group) => group.project.name), [
      'shared',
      'shared',
    ]);
    expect(snapshot.projects.map((group) => group.project.id).toSet(), {
      'cwd:/one/shared',
      'cwd:/two/shared',
    });
    expect(snapshot.projectlessThreads.single.id, 'c');
    expect(
      snapshot.allThreads.map((thread) => thread.id),
      isNot(contains('ephemeral')),
    );
  });

  test('unassigned threads inherit a project from an exact root path', () {
    final global = CodexGlobalStateData.tryParse(
      jsonEncode({
        'local-projects': {
          'first': {
            'id': 'first',
            'name': 'First',
            'rootPaths': ['/work/shared'],
          },
          'second': {
            'id': 'second',
            'name': 'Second',
            'rootPaths': ['/work/shared', '/work/second'],
          },
        },
        'project-order': ['second', 'first'],
        'projectless-thread-ids': ['explicit-projectless'],
        'thread-project-assignments': {
          'assigned': {'projectKind': 'local', 'projectId': 'first'},
        },
      }),
    );

    final snapshot = buildCodexCatalog([
      thread('inferred', cwd: '/work/second', updatedAt: 50),
      thread('ordered-collision', cwd: '/work/shared', updatedAt: 40),
      thread('assigned', cwd: '/work/second', updatedAt: 30),
      thread('nested', cwd: '/work/second/nested', updatedAt: 20),
      thread('explicit-projectless', cwd: '/work/second', updatedAt: 10),
    ], global);

    final byProject = {
      for (final group in snapshot.projects)
        group.project.id: group.threads.map((thread) => thread.id).toList(),
    };
    expect(byProject['second'], ['inferred', 'ordered-collision']);
    expect(byProject['first'], ['assigned']);
    expect(snapshot.projectlessThreads.map((thread) => thread.id), [
      'nested',
      'explicit-projectless',
    ]);
    expect(snapshot.projectNameForThread('inferred'), 'Second');
    expect(snapshot.projectNameForThread('ordered-collision'), 'Second');
  });

  test('local placements insert before an anchor only in the same group', () {
    final snapshot = buildCodexCatalog(
      [
        thread('before', cwd: '/work', updatedAt: 40),
        thread('current', cwd: '/work', updatedAt: 30),
        thread('new', cwd: '/work', updatedAt: 50),
        thread('other-newest', cwd: '/other', updatedAt: 60),
        thread('other-new', cwd: '/other', updatedAt: 55),
      ],
      null,
      insertBeforeByThreadId: {
        'new': 'current',
        'other-newest': 'current',
        'other-new': 'current',
      },
    );

    final groups = {
      for (final group in snapshot.projects)
        group.project.id: group.threads.map((thread) => thread.id).toList(),
    };
    expect(groups['cwd:/work'], ['before', 'new', 'current']);
    expect(groups['cwd:/other'], ['other-newest', 'other-new']);
  });

  test('parser and title helpers tolerate invalid and sparse values', () {
    expect(CodexGlobalStateData.tryParse('{invalid'), isNull);
    expect(CodexGlobalStateData.tryParse('{}'), isNull);
    expect(codexPathBasename(r'C:\work\motif\'), 'motif');
    expect(codexThreadTitle(thread('name', name: '  Named  ')), 'Named');
    expect(
      codexThreadTitle(thread('preview', preview: '\n  First line\nSecond')),
      'First line',
    );
    expect(codexThreadTitle(thread('empty')), 'Untitled thread');
  });

  test('timeline labels use local calendar-day boundaries', () {
    final now = DateTime(2026, 8, 11, 0, 5);
    int seconds(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;

    expect(
      codexThreadDateLabel(
        thread('today', updatedAt: seconds(DateTime(2026, 8, 11, 0, 1))),
        now: now,
      ),
      'Today',
    );
    expect(
      codexThreadDateLabel(
        thread('yesterday', updatedAt: seconds(DateTime(2026, 8, 10, 23, 59))),
        now: now,
      ),
      'Yesterday',
    );
    expect(
      codexThreadDateLabel(
        thread('older', updatedAt: seconds(DateTime(2026, 8, 9, 12))),
        now: now,
      ),
      '2026-08-09',
    );
  });
}

CodexThread thread(
  String id, {
  String cwd = '/work',
  String? name,
  String preview = '',
  int updatedAt = 1,
  bool ephemeral = false,
  CodexThreadStatus status = const CodexNotLoadedThreadStatus(),
}) => CodexThread(
  cliVersion: 'test',
  createdAt: updatedAt,
  cwd: CodexV2AbsolutePathBuf(cwd),
  ephemeral: ephemeral,
  id: id,
  modelProvider: 'openai',
  name: name,
  preview: preview,
  sessionId: id,
  source: const CodexSessionSource('cli'),
  status: status,
  turns: const [],
  updatedAt: updatedAt,
);
