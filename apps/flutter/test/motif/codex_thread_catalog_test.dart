import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_thread_catalog.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';

void main() {
  test(
    'uses server project identity and position, including empty projects',
    () {
      final snapshot = buildCodexCatalog(
        [
          thread('assigned', projectId: 'p1', cwd: '/different', updatedAt: 10),
          thread('pinned', projectId: 'p1', updatedAt: 20),
          thread('unassigned', cwd: '/work', updatedAt: 30),
          thread('deleted-project', projectId: 'gone', updatedAt: 40),
          thread('ephemeral', projectId: 'p1', ephemeral: true),
        ],
        [project('p1', position: 1), project('empty', position: 0)],
        pinnedThreadIds: ['pinned', 'pinned', 'missing'],
        selectedProjectId: 'p1',
      );
      expect(snapshot.projects.map((g) => g.project.id), ['empty', 'p1']);
      expect(snapshot.projects.first.threads, isEmpty);
      expect(snapshot.projects.last.threads.map((t) => t.id), ['assigned']);
      expect(snapshot.pinnedThreads.map((t) => t.id), ['pinned']);
      expect(snapshot.projectlessThreads.map((t) => t.id), [
        'deleted-project',
        'unassigned',
      ]);
      expect(snapshot.projectNameForThread('pinned'), 'p1');
      expect(snapshot.selectedProjectId, 'p1');
      expect(
        snapshot.allThreads.map((t) => t.id),
        isNot(contains('ephemeral')),
      );
    },
  );

  test('does not infer assignments from shared, exact, or nested roots', () {
    final snapshot = buildCodexCatalog(
      [
        thread('exact', cwd: '/work'),
        thread('nested', cwd: '/work/nested'),
        thread('assigned', projectId: 'second', cwd: '/elsewhere'),
      ],
      [project('first'), project('second')],
    );
    expect(snapshot.projects.first.threads, isEmpty);
    expect(snapshot.projects.last.threads.single.id, 'assigned');
    expect(snapshot.projectlessThreads.map((t) => t.id), ['exact', 'nested']);
    expect(buildCodexCatalog([thread('cwd')], const []).projects, isEmpty);
  });

  test(
    'project members sort by recency regardless of temporary placements',
    () {
      final snapshot = buildCodexCatalog(
        [
          thread('old', projectId: 'p', updatedAt: 10),
          thread('new', projectId: 'p', updatedAt: 5, recencyAt: 20),
        ],
        [project('p')],
        insertBeforeByThreadId: {'old': 'new'},
      );
      expect(snapshot.projects.single.threads.map((t) => t.id), ['new', 'old']);
    },
  );

  test('title and path helpers handle sparse values', () {
    expect(codexPathBasename(r'C:\work\motif\'), 'motif');
    expect(codexThreadTitle(thread('name', name: '  Named  ')), 'Named');
    expect(
      codexThreadTitle(thread('preview', preview: '\n  First line\nSecond')),
      'First line',
    );
    expect(codexThreadTitle(thread('empty')), 'Untitled thread');
  });

  test('fork names use the next available numeric suffix', () {
    final source = thread('source', name: 'Release notes');
    final second = thread('second', name: 'Release notes 2');
    final fourth = thread('fourth', name: 'Release notes 4');

    expect(
      nextCodexForkThreadName(source, [source, second, fourth]),
      'Release notes 3',
    );
    expect(
      nextCodexForkThreadName(second, [source, second, fourth]),
      'Release notes 3',
    );
  });

  test('managed worktree detection uses the app-server Codex home', () {
    expect(
      codexThreadIsManagedWorktree(
        thread('worktree', cwd: '/tmp/codex/worktrees/a1b2/motif'),
        '/tmp/codex',
      ),
      isTrue,
    );
    expect(
      codexThreadIsManagedWorktree(
        thread('checkout', cwd: '/work/motif'),
        '/tmp/codex',
      ),
      isFalse,
    );
    expect(
      codexThreadIsManagedWorktree(
        thread('root', cwd: '/tmp/codex/worktrees'),
        '/tmp/codex',
      ),
      isFalse,
    );
    expect(
      codexThreadIsManagedWorktree(
        thread('lookalike', cwd: '/tmp/codex/worktrees-old/a1b2/motif'),
        '/tmp/codex',
      ),
      isFalse,
    );
    expect(
      codexThreadIsManagedWorktree(
        thread('windows', cwd: r'C:\Users\me\.codex\worktrees\A1B2\motif'),
        r'c:\users\me\.codex\',
      ),
      isTrue,
    );
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
  String? projectId,
  String? name,
  String preview = '',
  int updatedAt = 1,
  int? recencyAt,
  bool ephemeral = false,
  CodexThreadStatus status = const CodexNotLoadedThreadStatus(),
}) => CodexThread(
  projectId: projectId,
  cliVersion: 'test',
  createdAt: updatedAt,
  cwd: CodexV2AbsolutePathBuf(cwd),
  ephemeral: ephemeral,
  id: id,
  modelProvider: 'openai',
  name: name,
  preview: preview,
  recencyAt: recencyAt,
  sessionId: id,
  source: const CodexSessionSource('cli'),
  status: status,
  turns: const [],
  updatedAt: updatedAt,
);

CodexProject project(String id, {int position = 0}) => CodexProject(
  id: id,
  name: id,
  roots: const [CodexProjectRoot(path: CodexV2AbsolutePathBuf('/work'))],
  position: position,
  metadata: const {},
  createdAt: 0,
  updatedAt: 0,
);
