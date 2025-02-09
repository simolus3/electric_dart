// ignore_for_file: unreachable_from_main

import 'dart:async';
import 'dart:convert';

import 'package:electricsql/src/auth/auth.dart';
import 'package:electricsql/src/drivers/sqlite3/sqlite3_adapter.dart'
    show SqliteAdapter;
import 'package:electricsql/src/drivers/sqlite3/sqlite3_adapter.dart' as adp
    show Transaction;
import 'package:electricsql/src/electric/adapter.dart' hide Transaction;
import 'package:electricsql/src/migrators/migrators.dart';
import 'package:electricsql/src/notifiers/mock.dart';
import 'package:electricsql/src/notifiers/notifiers.dart';
import 'package:electricsql/src/satellite/merge.dart';
import 'package:electricsql/src/satellite/mock.dart';
import 'package:electricsql/src/satellite/oplog.dart';
import 'package:electricsql/src/satellite/process.dart';
import 'package:electricsql/src/satellite/shapes/types.dart';
import 'package:electricsql/src/util/common.dart';
import 'package:electricsql/src/util/tablename.dart';
import 'package:electricsql/src/util/types.dart' hide Change;
import 'package:electricsql/src/util/types.dart' as t;
import 'package:fixnum/fixnum.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../support/satellite_helpers.dart';
import '../util/sqlite_errors.dart';
import 'common.dart';

late SatelliteTestContext context;

Future<void> runMigrations() async {
  await context.runMigrations();
}

Database get db => context.db;
DatabaseAdapter get adapter => context.adapter;
Migrator get migrator => context.migrator;
MockNotifier get notifier => context.notifier;
TableInfo get tableInfo => context.tableInfo;
DateTime get timestamp => context.timestamp;
SatelliteProcess get satellite => context.satellite;
MockSatelliteClient get client => context.client;
String get dbName => context.dbName;
AuthState get authState => context.authState;
AuthConfig get authConfig => context.authConfig;

const parentRecord = <String, Object?>{
  'id': 1,
  'value': 'incoming',
  'other': 1,
};

const childRecord = <String, Object?>{
  'id': 1,
  'parent': 1,
};

void main() {
  setUp(() async {
    context = await makeContext();
  });

  tearDown(() async {
    await context.cleanAndStopSatellite();
  });

  test('start creates system tables', () async {
    final conn = await satellite.start(context.authConfig);

    const sql = "select name from sqlite_master where type = 'table'";
    final rows = await adapter.query(Statement(sql));
    final names = rows.map((row) => row['name']! as String).toList();

    await conn.connectionFuture;

    expect(names, contains('_electric_oplog'));
  });

  test('load metadata', () async {
    await runMigrations();

    final meta = await loadSatelliteMetaTable(adapter);
    expect(meta, {
      'compensations': 1,
      'lsn': '',
      'clientId': '',
      'subscriptions': '',
    });
  });

  test('set persistent client id', () async {
    await satellite.start(authConfig);
    final clientId1 = satellite.authState!.clientId;
    await satellite.stop();

    await satellite.start(authConfig);

    final clientId2 = satellite.authState!.clientId;

    expect(clientId1, clientId2);
    // Give time for the starting performSnapshot to finish
    // Otherwise the database might not exist because the test ended
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('cannot UPDATE primary key', () async {
    await runMigrations();

    await adapter.run(Statement("INSERT INTO parent(id) VALUES ('1'),('2')"));

    await expectLater(
      adapter.run(Statement("UPDATE parent SET id='3' WHERE id = '1'")),
      throwsA(
        isA<SqliteException>().having(
          (SqliteException e) => e.extendedResultCode,
          'code',
          SqliteErrors.SQLITE_CONSTRAINT_TRIGGER,
        ),
      ),
    );
  });

  test('snapshot works', () async {
    await runMigrations();
    await satellite.setAuthState(authState);

    await adapter.run(Statement("INSERT INTO parent(id) VALUES ('1'),('2')"));

    final snapshotTimestamp = await satellite.performSnapshot();

    final clientId = satellite.authState!.clientId;
    final shadowTags = encodeTags([generateTag(clientId, snapshotTimestamp)]);

    final shadowRows = await adapter.query(
      Statement('SELECT tags FROM _electric_shadow'),
    );
    expect(shadowRows.length, 2);
    for (final row in shadowRows) {
      expect(row['tags'], shadowTags);
    }

    expect(notifier.notifications.length, 1);

    final changes = (notifier.notifications[0] as ChangeNotification).changes;
    final expectedChange = Change(
      qualifiedTablename: const QualifiedTablename('main', 'parent'),
      rowids: [1, 2],
    );

    expect(changes, [expectedChange]);
  });

  test('(regression) performSnapshot cant be called concurrently', () async {
    await runMigrations();
    await satellite.setAuthState(authState);

    satellite.updateDatabaseAdapter(
      SlowDatabaseAdapter((satellite.adapter as SqliteAdapter).db),
    );

    await expectLater(
      () async {
        final p1 = satellite.performSnapshot();
        final p2 = satellite.performSnapshot();
        await Future.wait([p1, p2]);
      }(),
      throwsA(
        isA<SatelliteException>()
            .having(
              (e) => e.code,
              'code',
              SatelliteErrorCode.internal,
            )
            .having((e) => e.message, 'message', 'already performing snapshot'),
      ),
    );
  });

  test('(regression) throttle with mutex prevents race when snapshot is slow',
      () async {
    await runMigrations();
    await satellite.setAuthState(authState);

    // delay termination of _performSnapshot
    satellite.updateDatabaseAdapter(
      SlowDatabaseAdapter((satellite.adapter as SqliteAdapter).db),
    );

    final p1 = satellite.throttledSnapshot();

    final completer = Completer<void>();
    Timer(const Duration(milliseconds: 50), () async {
      // call snapshot after throttle time has expired
      await satellite.throttledSnapshot();
      completer.complete();
    });
    final p2 = completer.future;

    // They don't throw
    await p1;
    await p2;
  });

  test('starting and stopping the process works', () async {
    await runMigrations();

    await adapter.run(Statement("INSERT INTO parent(id) VALUES ('1'),('2')"));

    final conn = await satellite.start(authConfig);
    await conn.connectionFuture;

    await Future<void>.delayed(opts.pollingInterval);

    // connect, 1st txn
    expect(notifier.notifications.length, 2);

    await adapter.run(Statement("INSERT INTO parent(id) VALUES ('3'),('4')"));
    await Future<void>.delayed(opts.pollingInterval);

    // 2nd txm
    expect(notifier.notifications.length, 3);

    await satellite.stop();
    await adapter.run(Statement("INSERT INTO parent(id) VALUES ('5'),('6')"));
    await Future<void>.delayed(opts.pollingInterval);

    // no txn notified
    expect(notifier.notifications.length, 4);

    final conn1 = await satellite.start(authConfig);
    await conn1.connectionFuture;
    await Future<void>.delayed(opts.pollingInterval);

    // connect, 4th txn
    expect(notifier.notifications.length, 6);
  });

  test('snapshots on potential data change', () async {
    await runMigrations();

    await adapter.run(Statement("INSERT INTO parent(id) VALUES ('1'),('2')"));

    expect(notifier.notifications.length, 0);

    notifier.potentiallyChanged();

    expect(notifier.notifications.length, 1);
  });

  // INSERT after DELETE shall nullify all non explicitly set columns
// If last operation is a DELETE, concurrent INSERT shall resurrect deleted
// values as in 'INSERT wins over DELETE and restored deleted values'
  test('snapshot of INSERT after DELETE', () async {
    await runMigrations();

    await adapter.run(
      Statement(
        "INSERT INTO parent(id, value) VALUES (1,'val1')",
      ),
    );
    await adapter.run(Statement('DELETE FROM parent WHERE id=1'));
    await adapter.run(Statement('INSERT INTO parent(id) VALUES (1)'));

    await satellite.setAuthState(authState);
    await satellite.performSnapshot();
    final entries = await satellite.getEntries();
    final clientId = satellite.authState!.clientId;

    final merged = localOperationsToTableChanges(
      entries,
      (DateTime timestamp) {
        return generateTag(clientId, timestamp);
      },
      kTestRelations,
    );
    final opLogTableChange = merged['main.parent']!['{"id":1}']!;
    final keyChanges = opLogTableChange.oplogEntryChanges;
    final resultingValue = keyChanges.changes['value']!.value;
    expect(resultingValue, null);
  });

  test('snapshot of INSERT with bigint', () async {
    await runMigrations();

    await adapter.run(
      Statement(
        'INSERT INTO bigIntTable(value) VALUES (1)',
      ),
    );

    await satellite.setAuthState(authState);
    await satellite.performSnapshot();
    final entries = await satellite.getEntries();
    final clientId = satellite.authState!.clientId;

    final merged = localOperationsToTableChanges(
      entries,
      (timestamp) {
        return generateTag(clientId, timestamp);
      },
      kTestRelations,
    );
    final opLogTableChange = merged['main.bigIntTable']!['{"value":"1"}']!;
    final keyChanges = opLogTableChange.oplogEntryChanges;
    final resultingValue = keyChanges.changes['value']!.value;
    expect(resultingValue, BigInt.from(1));
  });

  test('take snapshot and merge local wins', () async {
    await runMigrations();

    final incomingTs = DateTime.now().millisecondsSinceEpoch - 1;
    final incomingEntry = generateRemoteOplogEntry(
      tableInfo,
      'main',
      'parent',
      OpType.insert,
      incomingTs,
      encodeTags([
        generateTag('remote', DateTime.fromMillisecondsSinceEpoch(incomingTs)),
      ]),
      newValues: {
        'id': 1,
        'value': 'incoming',
      },
      oldValues: {},
    );
    await adapter.run(
      Statement(
        "INSERT INTO parent(id, value, other) VALUES (1, 'local', 1)",
      ),
    );

    await satellite.setAuthState(authState);
    final localTime = await satellite.performSnapshot();
    final clientId = satellite.authState!.clientId;

    final local = await satellite.getEntries();
    final localTimestamp =
        DateTime.parse(local[0].timestamp).millisecondsSinceEpoch;
    final merged = mergeEntries(
      clientId,
      local,
      'remote',
      [incomingEntry],
      kTestRelations,
    );
    final item = merged['main.parent']!['{"id":1}'];

    expect(
      item,
      ShadowEntryChanges(
        namespace: 'main',
        tablename: 'parent',
        primaryKeyCols: {'id': 1},
        optype: ChangesOpType.upsert,
        changes: {
          'id': OplogColumnChange(1, localTimestamp),
          'value': OplogColumnChange('local', localTimestamp),
          'other': OplogColumnChange(1, localTimestamp),
        },
        fullRow: {
          'id': 1,
          'value': 'local',
          'other': 1,
        },
        tags: [
          generateTag(clientId, localTime),
          generateTag(
            'remote',
            DateTime.fromMillisecondsSinceEpoch(incomingTs),
          ),
        ],
      ),
    );
  });

  test('take snapshot and merge incoming wins', () async {
    await runMigrations();

    await adapter.run(
      Statement(
        "INSERT INTO parent(id, value, other) VALUES (1, 'local', 1)",
      ),
    );

    await satellite.setAuthState(authState);
    final clientId = satellite.authState!.clientId;
    await satellite.performSnapshot();

    final local = await satellite.getEntries();
    final localTimestamp = DateTime.parse(local[0].timestamp);

    final incomingTs = DateTime.fromMillisecondsSinceEpoch(
      localTimestamp.millisecondsSinceEpoch + 1,
    );

    final incomingEntry = generateRemoteOplogEntry(
      tableInfo,
      'main',
      'parent',
      OpType.insert,
      incomingTs.millisecondsSinceEpoch,
      genEncodedTags('remote', [incomingTs]),
      newValues: {
        'id': 1,
        'value': 'incoming',
      },
      oldValues: {},
    );

    final merged = mergeEntries(
      clientId,
      local,
      'remote',
      [incomingEntry],
      kTestRelations,
    );
    final item = merged['main.parent']!['{"id":1}'];

    expect(
      item,
      ShadowEntryChanges(
        namespace: 'main',
        tablename: 'parent',
        primaryKeyCols: {'id': 1},
        optype: ChangesOpType.upsert,
        changes: {
          'id': OplogColumnChange(1, incomingTs.millisecondsSinceEpoch),
          'value':
              OplogColumnChange('incoming', incomingTs.millisecondsSinceEpoch),
          'other': OplogColumnChange(1, localTimestamp.millisecondsSinceEpoch),
        },
        fullRow: {
          'id': 1,
          'value': 'incoming',
          'other': 1,
        },
        tags: [
          generateTag(clientId, localTimestamp),
          generateTag('remote', incomingTs),
        ],
      ),
    );
  });

  test('merge incoming wins on persisted ops', () async {
    await runMigrations();
    await satellite.setAuthState(authState);
    satellite.relations = kTestRelations;

    // This operation is persisted
    await adapter.run(
      Statement(
        "INSERT INTO parent(id, value, other) VALUES (1, 'local', 1)",
      ),
    );
    await satellite.performSnapshot();
    final [originalInsert] = await satellite.getEntries();
    final [tx] = toTransactions([originalInsert], satellite.relations);
    tx.origin = authState.clientId;
    await satellite.applyTransaction(tx);

    // Verify that GC worked as intended and the oplog entry was deleted
    expect(await satellite.getEntries(), isEmpty);

    // This operation is done offline
    await adapter.run(
      Statement("UPDATE parent SET value = 'new local' WHERE id = 1"),
    );
    await satellite.performSnapshot();
    final [offlineInsert] = await satellite.getEntries();
    final offlineTimestamp = DateTime.parse(offlineInsert.timestamp);

    // This operation is done concurrently with offline but at a later point in time. It's sent immediately on connection
    final incomingTs = offlineTimestamp.add(const Duration(milliseconds: 1));
    final firstIncomingEntry = generateRemoteOplogEntry(
      tableInfo,
      'main',
      'parent',
      OpType.update,
      incomingTs.millisecondsSinceEpoch,
      genEncodedTags('remote', [incomingTs]),
      newValues: {'id': 1, 'value': 'incoming'},
      oldValues: {'id': 1, 'value': 'local'},
    );

    final firstIncomingTx = Transaction(
      origin: 'remote',
      commitTimestamp: Int64(incomingTs.millisecondsSinceEpoch),
      changes: [opLogEntryToChange(firstIncomingEntry, satellite.relations)],
      lsn: [],
    );
    await satellite.applyTransaction(firstIncomingTx);

    var [row] = await adapter.query(
      Statement('SELECT value FROM parent WHERE id = 1'),
    );
    final value1 = row['value']!;
    expect(
      value1,
      'incoming',
      reason:
          'LWW conflict merge of the incoming transaction should lead to incoming operation winning',
    );

    // And after the offline transaction was sent, the resolved no-op transaction comes in
    final secondIncomingEntry = generateRemoteOplogEntry(
      tableInfo,
      'main',
      'parent',
      OpType.update,
      offlineTimestamp.millisecondsSinceEpoch,
      encodeTags([
        generateTag('remote', incomingTs),
        generateTag(authState.clientId, offlineTimestamp),
      ]),
      newValues: {'id': 1, 'value': 'incoming'},
      oldValues: {'id': 1, 'value': 'incoming'},
    );

    final secondIncomingTx = Transaction(
      origin: authState.clientId,
      commitTimestamp: Int64(offlineTimestamp.millisecondsSinceEpoch),
      changes: [opLogEntryToChange(secondIncomingEntry, satellite.relations)],
      lsn: [],
    );
    await satellite.applyTransaction(secondIncomingTx);

    [row] = await adapter.query(
      Statement('SELECT value FROM parent WHERE id = 1'),
    );
    final value2 = row['value']!;
    expect(
      value2,
      'incoming',
      reason:
          'Applying the resolved write from the round trip should be a no-op',
    );
  });

  test('apply does not add anything to oplog', () async {
    await runMigrations();
    await adapter.run(
      Statement(
        "INSERT INTO parent(id, value, other) VALUES (1, 'local', null)",
      ),
    );

    await satellite.setAuthState(authState);
    final clientId = satellite.authState!.clientId;

    final localTimestamp = await satellite.performSnapshot();

    final incomingTs = DateTime.now();
    final incomingEntry = generateRemoteOplogEntry(
      tableInfo,
      'main',
      'parent',
      OpType.insert,
      incomingTs.millisecondsSinceEpoch,
      genEncodedTags('remote', [incomingTs]),
      newValues: {
        'id': 1,
        'value': 'incoming',
        'other': 1,
      },
      oldValues: {},
    );

    satellite.relations =
        kTestRelations; // satellite must be aware of the relations in order to turn `DataChange`s into `OpLogEntry`s

    final incomingChange = opLogEntryToChange(incomingEntry, kTestRelations);
    final incomingTx = Transaction(
      origin: 'remote',
      commitTimestamp: Int64(incomingTs.millisecondsSinceEpoch),
      changes: [incomingChange],
      lsn: [],
    );

    await satellite.applyTransaction(incomingTx);

    await satellite.performSnapshot();

    const sql = 'SELECT * from parent WHERE id=1';
    final row = (await adapter.query(Statement(sql)))[0];
    expect(row['value']! as String, 'incoming');
    expect(row['other']! as int, 1);

    final localEntries = await satellite.getEntries();
    final shadowEntry =
        await getMatchingShadowEntries(adapter, oplog: localEntries[0]);

    expect(
      encodeTags([
        generateTag(clientId, localTimestamp),
        generateTag('remote', incomingTs),
      ]),
      shadowEntry[0].tags,
    );

    //t.deepEqual(shadowEntries, shadowEntries2)
    expect(localEntries.length, 1);
  });

  test('apply incoming with no local', () async {
    await runMigrations();

    final incomingTs = DateTime.now();
    final incomingEntry = generateRemoteOplogEntry(
      tableInfo,
      'main',
      'parent',
      OpType.delete,
      incomingTs.millisecondsSinceEpoch,
      genEncodedTags('remote', []),
      newValues: {
        'id': 1,
        'value': 'incoming',
        'otherValue': 1,
      },
      oldValues: {},
    );

    // satellite must be aware of the relations in order to deserialise oplog entries
    satellite.relations = kTestRelations;

    await satellite.setAuthState(authState);
    await satellite.apply([incomingEntry], 'remote');

    const sql = 'SELECT * from parent WHERE id=1';
    final rows = await adapter.query(Statement(sql));
    final shadowEntries = await getMatchingShadowEntries(adapter);

    expect(shadowEntries, isEmpty);
    expect(rows, isEmpty);
  });

  test('apply empty incoming', () async {
    await runMigrations();

    await satellite.setAuthState(authState);

    await satellite.apply([], 'external');
  });

  test('apply incoming with null on column with default', () async {
    await runMigrations();

    final incomingTs = DateTime.now();
    final incomingEntry = generateRemoteOplogEntry(
      tableInfo,
      'main',
      'parent',
      OpType.insert,
      incomingTs.millisecondsSinceEpoch,
      genEncodedTags('remote', [incomingTs]),
      newValues: {
        'id': 1234,
        'value': 'incoming',
        'other': null,
      },
      oldValues: {},
    );

    await satellite.setAuthState(authState);

    satellite.relations =
        kTestRelations; // satellite must be aware of the relations in order to turn `DataChange`s into `OpLogEntry`s

    final incomingChange = opLogEntryToChange(incomingEntry, kTestRelations);
    final incomingTx = Transaction(
      origin: 'remote',
      commitTimestamp: Int64(incomingTs.millisecondsSinceEpoch),
      changes: [incomingChange],
      lsn: [],
    );
    await satellite.applyTransaction(incomingTx);

    const sql = "SELECT * from main.parent WHERE value='incoming'";
    final rows = await adapter.query(Statement(sql));

    expect(rows[0]['other'], null);
  });

  test('apply incoming with undefined on column with default', () async {
    await runMigrations();

    final incomingTs = DateTime.now();
    final incomingEntry = generateRemoteOplogEntry(
      tableInfo,
      'main',
      'parent',
      OpType.insert,
      incomingTs.millisecondsSinceEpoch,
      genEncodedTags('remote', [incomingTs]),
      newValues: {
        'id': 1234,
        'value': 'incoming',
      },
      oldValues: {},
    );

    await satellite.setAuthState(authState);

    satellite.relations =
        kTestRelations; // satellite must be aware of the relations in order to turn `DataChange`s into `OpLogEntry`s

    final incomingChange = opLogEntryToChange(incomingEntry, kTestRelations);
    final incomingTx = Transaction(
      origin: 'remote',
      commitTimestamp: Int64(incomingTs.millisecondsSinceEpoch),
      changes: [incomingChange],
      lsn: [],
    );
    await satellite.applyTransaction(incomingTx);

    const sql = "SELECT * from main.parent WHERE value='incoming'";
    final rows = await adapter.query(Statement(sql));

    expect(rows[0]['other'], 0);
  });

  test('INSERT wins over DELETE and restored deleted values', () async {
    await runMigrations();
    await satellite.setAuthState(authState);
    final clientId = satellite.authState!.clientId;

    final localTs = DateTime.now();
    final incomingTs = localTs.add(const Duration(milliseconds: 1));

    final incoming = [
      generateRemoteOplogEntry(
        tableInfo,
        'main',
        'parent',
        OpType.insert,
        incomingTs.millisecondsSinceEpoch,
        genEncodedTags('remote', [incomingTs]),
        newValues: {
          'id': 1,
          'other': 1,
        },
        oldValues: {},
      ),
      generateRemoteOplogEntry(
        tableInfo,
        'main',
        'parent',
        OpType.delete,
        incomingTs.millisecondsSinceEpoch,
        genEncodedTags('remote', []),
        newValues: {
          'id': 1,
        },
        oldValues: {},
      ),
    ];

    final local = [
      generateLocalOplogEntry(
        tableInfo,
        'main',
        'parent',
        OpType.insert,
        localTs.millisecondsSinceEpoch,
        genEncodedTags(clientId, [localTs]),
        newValues: {
          'id': 1,
          'value': 'local',
          'other': null,
        },
      ),
    ];

    final merged =
        mergeEntries(clientId, local, 'remote', incoming, kTestRelations);
    final item = merged['main.parent']!['{"id":1}'];

    expect(
      item,
      ShadowEntryChanges(
        namespace: 'main',
        tablename: 'parent',
        primaryKeyCols: {'id': 1},
        optype: ChangesOpType.upsert,
        changes: {
          'id': OplogColumnChange(1, incomingTs.millisecondsSinceEpoch),
          'value': OplogColumnChange('local', localTs.millisecondsSinceEpoch),
          'other': OplogColumnChange(1, incomingTs.millisecondsSinceEpoch),
        },
        fullRow: {
          'id': 1,
          'value': 'local',
          'other': 1,
        },
        tags: [
          generateTag(clientId, localTs),
          generateTag('remote', incomingTs),
        ],
      ),
    );
  });

  test('concurrent updates take all changed values', () async {
    await runMigrations();
    await satellite.setAuthState(authState);
    final clientId = satellite.authState!.clientId;

    final localTs = DateTime.now().millisecondsSinceEpoch;
    final incomingTs = localTs + 1;

    final incoming = [
      generateRemoteOplogEntry(
        tableInfo,
        'main',
        'parent',
        OpType.update,
        incomingTs,
        genEncodedTags(
          'remote',
          [DateTime.fromMillisecondsSinceEpoch(incomingTs)],
        ),
        newValues: {
          'id': 1,
          'value': 'remote', // the only modified column
          'other': 0,
        },
        oldValues: {
          'id': 1,
          'value': 'local',
          'other': 0,
        },
      ),
    ];

    final local = [
      generateLocalOplogEntry(
        tableInfo,
        'main',
        'parent',
        OpType.update,
        localTs,
        genEncodedTags(
          clientId,
          [DateTime.fromMillisecondsSinceEpoch(localTs)],
        ),
        newValues: {
          'id': 1,
          'value': 'local',
          'other': 1, // the only modified column
        },
        oldValues: {
          'id': 1,
          'value': 'local',
          'other': 0,
        },
      ),
    ];

    final merged =
        mergeEntries(clientId, local, 'remote', incoming, kTestRelations);
    final item = merged['main.parent']!['{"id":1}']!;

    // The incoming entry modified the value of the `value` column to `'remote'`
    // The local entry concurrently modified the value of the `other` column to 1.
    // The merged entries should have `value = 'remote'` and `other = 1`.
    expect(
      item,
      ShadowEntryChanges(
        namespace: 'main',
        tablename: 'parent',
        primaryKeyCols: {'id': 1},
        optype: ChangesOpType.upsert,
        changes: {
          'value': OplogColumnChange('remote', incomingTs),
          'other': OplogColumnChange(1, localTs),
        },
        fullRow: {
          'id': 1,
          'value': 'remote',
          'other': 1,
        },
        tags: [
          generateTag(clientId, DateTime.fromMillisecondsSinceEpoch(localTs)),
          generateTag(
            'remote',
            DateTime.fromMillisecondsSinceEpoch(incomingTs),
          ),
        ],
      ),
    );
  });

  test('merge incoming with empty local', () async {
    await runMigrations();
    await satellite.setAuthState(authState);
    final clientId = satellite.authState!.clientId;

    final localTs = DateTime.now();
    final incomingTs = localTs.add(const Duration(milliseconds: 1));

    final incoming = [
      generateRemoteOplogEntry(
        tableInfo,
        'main',
        'parent',
        OpType.insert,
        incomingTs.millisecondsSinceEpoch,
        genEncodedTags('remote', [incomingTs]),
        newValues: {
          'id': 1,
        },
        oldValues: {},
      ),
    ];

    final local = <OplogEntry>[];
    final merged =
        mergeEntries(clientId, local, 'remote', incoming, kTestRelations);
    final item = merged['main.parent']!['{"id":1}'];

    expect(
      item,
      ShadowEntryChanges(
        namespace: 'main',
        tablename: 'parent',
        primaryKeyCols: {'id': 1},
        optype: ChangesOpType.upsert,
        changes: {
          'id': OplogColumnChange(1, incomingTs.millisecondsSinceEpoch),
        },
        fullRow: {
          'id': 1,
        },
        tags: [generateTag('remote', incomingTs)],
      ),
    );
  });

  test('compensations: referential integrity is enforced', () async {
    await runMigrations();

    await adapter.run(Statement('PRAGMA foreign_keys = ON'));
    await satellite.setMeta('compensations', 0);
    await adapter.run(
      Statement(
        "INSERT INTO main.parent(id, value) VALUES (1, '1')",
      ),
    );

    await expectLater(
      adapter
          .run(Statement('INSERT INTO main.child(id, parent) VALUES (1, 2)')),
      throwsA(
        isA<SqliteException>().having(
          (SqliteException e) => e.extendedResultCode,
          'code',
          SqliteErrors.SQLITE_CONSTRAINT_FOREIGNKEY,
        ),
      ),
    );
  });

  test('compensations: incoming operation breaks referential integrity',
      () async {
    await runMigrations();

    await adapter.run(Statement('PRAGMA foreign_keys = ON;'));
    await satellite.setMeta('compensations', 0);
    await satellite.setAuthState(authState);

    final incoming = generateLocalOplogEntry(
      tableInfo,
      'main',
      'child',
      OpType.insert,
      timestamp.millisecondsSinceEpoch,
      genEncodedTags('remote', [timestamp]),
      newValues: {
        'id': 1,
        'parent': 1,
      },
    );

    // await satellite.setAuthState(authState);

    satellite.relations =
        kTestRelations; // satellite must be aware of the relations in order to turn `DataChange`s into `OpLogEntry`s

    final incomingChange = opLogEntryToChange(incoming, kTestRelations);
    final incomingTx = Transaction(
      origin: 'remote',
      commitTimestamp: Int64(timestamp.millisecondsSinceEpoch),
      changes: [incomingChange],
      lsn: [],
    );

    await expectLater(
      satellite.applyTransaction(incomingTx),
      throwsA(
        isA<SqliteException>().having(
          (SqliteException e) => e.extendedResultCode,
          'code',
          SqliteErrors.SQLITE_CONSTRAINT_FOREIGNKEY,
        ),
      ),
    );
  });

  test(
      'compensations: incoming operations accepted if restore referential integrity',
      () async {
    await runMigrations();

    await adapter.run(Statement('PRAGMA foreign_keys = ON;'));
    await satellite.setMeta('compensations', 0);
    await satellite.setAuthState(authState);
    final clientId = satellite.authState!.clientId;

    final childInsertEntry = generateRemoteOplogEntry(
      tableInfo,
      'main',
      'child',
      OpType.insert,
      timestamp.millisecondsSinceEpoch,
      genEncodedTags(clientId, [timestamp]),
      newValues: {
        'id': 1,
        'parent': 1,
      },
    );

    final parentInsertEntry = generateRemoteOplogEntry(
      tableInfo,
      'main',
      'parent',
      OpType.insert,
      timestamp.millisecondsSinceEpoch,
      genEncodedTags(clientId, [timestamp]),
      newValues: {
        'id': 1,
      },
    );

    await adapter.run(
      Statement(
        "INSERT INTO main.parent(id, value) VALUES (1, '1')",
      ),
    );
    await adapter.run(Statement('DELETE FROM main.parent WHERE id=1'));

    await satellite.performSnapshot();

    satellite.relations =
        kTestRelations; // satellite must be aware of the relations in order to turn `DataChange`s into `OpLogEntry`s

    final childInsertChange =
        opLogEntryToChange(childInsertEntry, kTestRelations);
    final parentInsertChange =
        opLogEntryToChange(parentInsertEntry, kTestRelations);
    final insertChildAndParentTx = Transaction(
      origin: 'remote',
      commitTimestamp: Int64(
        DateTime.now().millisecondsSinceEpoch,
      ), // timestamp is not important for this test, it is only used to GC the oplog
      changes: [childInsertChange, parentInsertChange],
      lsn: [],
    );
    await satellite.applyTransaction(insertChildAndParentTx);

    final rows = await adapter.query(
      Statement(
        'SELECT * from main.parent WHERE id=1',
      ),
    );

    // Not only does the parent exist.
    expect(rows.length, 1);

    // But it's also recreated with deleted values.
    expect(rows[0]['value'], '1');
  });

  test('compensations: using triggers with flag 0', () async {
    await runMigrations();

    await adapter.run(Statement('PRAGMA foreign_keys = ON'));
    await satellite.setMeta('compensations', 0);

    await adapter.run(
      Statement("INSERT INTO main.parent(id, value) VALUES (1, '1')"),
    );
    await satellite.setAuthState(authState);
    final ts = await satellite.performSnapshot();
    await satellite.garbageCollectOplog(ts);

    await adapter
        .run(Statement('INSERT INTO main.child(id, parent) VALUES (1, 1)'));
    await satellite.performSnapshot();

    final timestamp = DateTime.now();
    final incoming = generateRemoteOplogEntry(
      tableInfo,
      'main',
      'parent',
      OpType.delete,
      timestamp.millisecondsSinceEpoch,
      genEncodedTags('remote', []),
      newValues: {
        'id': 1,
      },
    );

    satellite.relations =
        kTestRelations; // satellite must be aware of the relations in order to turn `DataChange`s into `OpLogEntry`s

    final incomingChange = opLogEntryToChange(incoming, kTestRelations);
    final incomingTx = Transaction(
      origin: 'remote',
      commitTimestamp: Int64(timestamp.millisecondsSinceEpoch),
      changes: [incomingChange],
      lsn: [],
    );

    await expectLater(
      satellite.applyTransaction(incomingTx),
      throwsA(
        isA<SqliteException>().having(
          (SqliteException e) => e.extendedResultCode,
          'code',
          SqliteErrors.SQLITE_CONSTRAINT_FOREIGNKEY,
        ),
      ),
    );
  });

  test('compensations: using triggers with flag 1', () async {
    await runMigrations();

    await adapter.run(Statement('PRAGMA foreign_keys = ON'));
    await satellite.setMeta('compensations', 1);

    await adapter.run(
      Statement("INSERT INTO main.parent(id, value) VALUES (1, '1')"),
    );
    await satellite.setAuthState(authState);
    final ts = await satellite.performSnapshot();
    await satellite.garbageCollectOplog(ts);

    await adapter
        .run(Statement('INSERT INTO main.child(id, parent) VALUES (1, 1)'));
    await satellite.performSnapshot();

    final timestamp = DateTime.now();
    final incoming = [
      generateRemoteOplogEntry(
        tableInfo,
        'main',
        'parent',
        OpType.delete,
        timestamp.millisecondsSinceEpoch,
        genEncodedTags('remote', []),
        newValues: {
          'id': 1,
        },
      ),
    ];

    // satellite must be aware of the relations in order to deserialise oplog entries
    satellite.relations = kTestRelations;

    // Should not throw
    await satellite.apply(incoming, 'remote');
  });

  test('get oplogEntries from transaction', () async {
    await runMigrations();

    final relations = await satellite.getLocalRelations();

    final transaction = DataTransaction(
      lsn: kDefaultLogPos,
      commitTimestamp: Int64.ZERO,
      changes: [
        t.DataChange(
          relation: relations['parent']!,
          type: DataChangeType.insert,
          record: {'id': 0},
          tags: [], // proper values are not relevent here
        ),
      ],
    );

    final expected = OplogEntry(
      namespace: 'main',
      tablename: 'parent',
      optype: OpType.insert,
      newRow: '{"id":0}',
      oldRow: null,
      primaryKey: '{"id":0}',
      rowid: -1,
      timestamp: '1970-01-01T00:00:00.000Z',
      clearTags: encodeTags([]),
    );

    final opLog = fromTransaction(transaction, relations);
    expect(opLog[0], expected);
  });

  test('get transactions from opLogEntries', () async {
    await runMigrations();

    final opLogEntries = <OplogEntry>[
      OplogEntry(
        namespace: 'public',
        tablename: 'parent',
        optype: OpType.insert,
        newRow: '{"id":0}',
        oldRow: null,
        primaryKey: '{"id":0}',
        rowid: 1,
        timestamp: '1970-01-01T00:00:00.000Z',
        clearTags: encodeTags([]),
      ),
      OplogEntry(
        namespace: 'public',
        tablename: 'parent',
        optype: OpType.update,
        newRow: '{"id":1}',
        oldRow: '{"id":1}',
        primaryKey: '{"id":1}',
        rowid: 2,
        timestamp: '1970-01-01T00:00:00.000Z',
        clearTags: encodeTags([]),
      ),
      OplogEntry(
        namespace: 'public',
        tablename: 'parent',
        optype: OpType.insert,
        newRow: '{"id":2}',
        oldRow: null,
        primaryKey: '{"id":0}',
        rowid: 3,
        timestamp: '1970-01-01T00:00:01.000Z',
        clearTags: encodeTags([]),
      ),
    ];

    final expected = <DataTransaction>[
      DataTransaction(
        lsn: numberToBytes(2),
        commitTimestamp: Int64.ZERO,
        changes: [
          t.DataChange(
            relation: kTestRelations['parent']!,
            type: DataChangeType.insert,
            record: {'id': 0},
            oldRecord: null,
            tags: [],
          ),
          t.DataChange(
            relation: kTestRelations['parent']!,
            type: DataChangeType.update,
            record: {'id': 1},
            oldRecord: {'id': 1},
            tags: [],
          ),
        ],
      ),
      DataTransaction(
        lsn: numberToBytes(3),
        commitTimestamp: Int64(1000),
        changes: [
          t.DataChange(
            relation: kTestRelations['parent']!,
            type: DataChangeType.insert,
            record: {'id': 2},
            oldRecord: null,
            tags: [],
          ),
        ],
      ),
    ];

    final opLog = toTransactions(opLogEntries, kTestRelations);
    expect(opLog, expected);
  });

  test('handling connectivity state change stops queueing operations',
      () async {
    await runMigrations();
    await satellite.start(authConfig);

    await adapter.run(
      Statement(
        "INSERT INTO parent(id, value, other) VALUES (1, 'local', 1)",
      ),
    );

    await satellite.performSnapshot();

    // We should have sent (or at least enqueued to send) one row
    final sentLsn = satellite.client.getLastSentLsn();
    expect(sentLsn, numberToBytes(1));

    await satellite
        .handleConnectivityStateChange(ConnectivityState.disconnected);

    await adapter.run(
      Statement(
        "INSERT INTO parent(id, value, other) VALUES (2, 'local', 1)",
      ),
    );

    await satellite.performSnapshot();

    // Since connectivity is down, that row isn't yet sent
    final lsn1 = satellite.client.getLastSentLsn();
    expect(lsn1, sentLsn);

    // Once connectivity is restored, we will immediately run a snapshot to send pending rows
    await satellite.handleConnectivityStateChange(ConnectivityState.available);
    // Wait for snapshot to run
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final lsn2 = satellite.client.getLastSentLsn();
    expect(lsn2, numberToBytes(2));
  });

  test(
      'garbage collection is triggered when transaction from the same origin is replicated',
      () async {
    await runMigrations();
    await satellite.start(authConfig);

    await adapter.run(
      Statement(
        "INSERT INTO parent(id, value, other) VALUES (1, 'local', 1);",
      ),
    );
    await adapter.run(
      Statement(
        "UPDATE parent SET value = 'local', other = 2 WHERE id = 1;",
      ),
    );

    // Before snapshot, we didn't send anything
    final lsn1 = satellite.client.getLastSentLsn();
    expect(lsn1, numberToBytes(0));

    // Snapshot sends these oplog entries
    await satellite.performSnapshot();
    final lsn2 = satellite.client.getLastSentLsn();
    expect(lsn2, numberToBytes(2));

    final oldOplog = await satellite.getEntries();
    final transactions = toTransactions(oldOplog, kTestRelations);

    final clientId = satellite.authState!.clientId;
    transactions[0].origin = clientId;

    // Transaction containing these oplogs is applies, which means we delete them
    await satellite.applyTransaction(transactions[0]);
    final newOplog = await satellite.getEntries();
    expect(newOplog, isEmpty);
  });

  // stub client and make satellite throw the error with option off/succeed with option on
  test('clear database on BEHIND_WINDOW', () async {
    await runMigrations();

    final base64lsn = base64.encode(numberToBytes(kMockBehindWindowLsn));
    await satellite.setMeta('lsn', base64lsn);
    try {
      final conn = await satellite.start(authConfig);
      await conn.connectionFuture;
      final lsnAfter = await satellite.getMeta<String?>('lsn');
      expect(lsnAfter, isNot(base64lsn));
    } catch (e) {
      fail('start should not throw');
    }

    // TODO: test clear subscriptions
  });

  test('throw other replication errors', () async {
    await runMigrations();

    final base64lsn = base64.encode(numberToBytes(kMockInternalError));
    await satellite.setMeta('lsn', base64lsn);

    int numExpects = 0;

    final conn = await satellite.start(authConfig);
    await Future.wait<dynamic>(
      [
        satellite.initializing!.waitOn(),
        conn.connectionFuture,
      ].map(
        (f) => f.onError<SatelliteException>((e, st) {
          numExpects++;
          expect(e.code, SatelliteErrorCode.internal);
        }),
      ),
    );

    expect(numExpects, 2);
  });

  test('apply shape data and persist subscription', () async {
    await runMigrations();

    const namespace = 'main';
    const tablename = 'parent';
    const qualified = QualifiedTablename(namespace, tablename);

    // relations must be present at subscription delivery
    client.setRelations(kTestRelations);
    client.setRelationData(tablename, parentRecord);

    final conn = await satellite.start(authConfig);
    await conn.connectionFuture;

    final shapeDef = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: tablename)],
    );

    satellite.relations = kTestRelations;

    final ShapeSubscription(synced: synced) =
        await satellite.subscribe([shapeDef]);
    await synced;

// first notification is 'connected'
    expect(notifier.notifications.length, 2);
    final changeNotification = notifier.notifications[1] as ChangeNotification;
    expect(changeNotification.changes.length, 1);
    expect(
      changeNotification.changes[0],
      Change(
        qualifiedTablename: qualified,
        rowids: [],
      ),
    );

    try {
      final row = await adapter.query(
        Statement(
          'SELECT id FROM $qualified',
        ),
      );
      expect(row.length, 1);

      final shadowRows = await adapter.query(
        Statement(
          'SELECT tags FROM _electric_shadow',
        ),
      );
      expect(shadowRows.length, 1);

      final subsMeta = await satellite.getMeta<String>('subscriptions');
      final subsObj = json.decode(subsMeta) as Map<String, Object?>;
      expect(subsObj.length, 1);

      // Check that we save the LSN sent by the mock
      expect(satellite.debugLsn, base64.decode('MTIz'));
    } catch (e, st) {
      fail('Reason: $e\n$st');
    }
  });

  test(
      '(regression) shape subscription succeeds even if subscription data is delivered before the SatSubsReq RPC call receives its SatSubsResp answer',
      () async {
    await runMigrations();

    const tablename = 'parent';

    // relations must be present at subscription delivery
    client.setRelations(kTestRelations);
    client.setRelationData(tablename, parentRecord);

    final conn = await satellite.start(authConfig);
    await conn.connectionFuture;

    final shapeDef = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: tablename)],
    );

    satellite.relations = kTestRelations;

    // Enable the deliver first flag in the mock client
    // such that the subscription data is delivered before the
    // subscription promise is resolved
    final mockClient = satellite.client as MockSatelliteClient;
    mockClient.enableDeliverFirst();

    final ShapeSubscription(:synced) = await satellite.subscribe([shapeDef]);
    await synced;

    // doesn't throw
  });

  test('multiple subscriptions for the same shape are deduplicated', () async {
    await runMigrations();

    const tablename = 'parent';

    // relations must be present at subscription delivery
    client.setRelations(kTestRelations);
    client.setRelationData(tablename, parentRecord);

    final conn = await satellite.start(authConfig);
    await conn.connectionFuture;

    final shapeDef = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: tablename)],
    );

    satellite.relations = kTestRelations;

    // None of the following cases should throw

    // We should dedupe subscriptions that are done at the same time
    final [sub1, sub2] = await Future.wait([
      satellite.subscribe([shapeDef]),
      satellite.subscribe([shapeDef]),
    ]);
    // That are done after first await but before the data
    final sub3 = await satellite.subscribe([shapeDef]);
    // And that are done after previous data is resolved
    await Future.wait([sub1.synced, sub2.synced, sub3.synced]);
    final sub4 = await satellite.subscribe([shapeDef]);

    await sub4.synced;

    // And be "merged" into one subscription
    expect(satellite.subscriptions.getFulfilledSubscriptions().length, 1);
  });

  test('applied shape data will be acted upon correctly', () async {
    await runMigrations();

    const namespace = 'main';
    const tablename = 'parent';
    final qualified = const QualifiedTablename(namespace, tablename).toString();

    // relations must be present at subscription delivery
    client.setRelations(kTestRelations);
    client.setRelationData(tablename, parentRecord);

    final conn = await satellite.start(authConfig);
    await conn.connectionFuture;

    final shapeDef = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: tablename)],
    );

    satellite.relations = kTestRelations;
    final ShapeSubscription(:synced) = await satellite.subscribe([shapeDef]);
    await synced;

    // wait for process to apply shape data
    try {
      final row = await adapter.query(
        Statement(
          'SELECT id FROM $qualified',
        ),
      );
      expect(row.length, 1);

      final shadowRows = await adapter.query(
        Statement(
          'SELECT * FROM _electric_shadow',
        ),
      );
      expect(shadowRows.length, 1);
      expect(shadowRows[0]['namespace'], 'main');
      expect(shadowRows[0]['tablename'], 'parent');

      await adapter.run(Statement('DELETE FROM $qualified WHERE id = 1'));
      await satellite.performSnapshot();

      final oplogs =
          await adapter.query(Statement('SELECT * FROM _electric_oplog'));
      expect(oplogs[0]['clearTags'], isNot('[]'));
    } catch (e, st) {
      fail('Reason: $e\n$st');
    }
  });

  test(
      'a subscription that failed to apply because of FK constraint triggers GC',
      () async {
    await runMigrations();

    const tablename = 'child';
    const namespace = 'main';
    final qualified = const QualifiedTablename(namespace, tablename).toString();

    // relations must be present at subscription delivery
    client.setRelations(kTestRelations);
    client.setRelationData(tablename, childRecord);

    final conn = await satellite.start(authConfig);
    await conn.connectionFuture;

    final shapeDef1 = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: tablename)],
    );

    satellite.relations = kTestRelations;
    final ShapeSubscription(synced: dataReceived) =
        await satellite.subscribe([shapeDef1]);
    await dataReceived; // wait for subscription to be fulfilled

    try {
      final row = await adapter.query(
        Statement(
          'SELECT id FROM $qualified',
        ),
      );

      expect(row.length, 0);
    } catch (e, st) {
      fail('Reason: $e\n$st');
    }
  });

  test('a second successful subscription', () async {
    await runMigrations();

    const tablename = 'child';
    final qualified = const QualifiedTablename('main', tablename).toString();

    // relations must be present at subscription delivery
    client.setRelations(kTestRelations);
    client.setRelationData('parent', parentRecord);
    client.setRelationData(tablename, childRecord);

    final conn = await satellite.start(authConfig);
    await conn.connectionFuture;

    final shapeDef1 = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: 'parent')],
    );
    final ClientShapeDefinition shapeDef2 = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: tablename)],
    );

    satellite.relations = kTestRelations;
    await satellite.subscribe([shapeDef1]);
    final ShapeSubscription(synced: synced) =
        await satellite.subscribe([shapeDef2]);
    await synced;

    try {
      final row = await adapter.query(
        Statement(
          'SELECT id FROM $qualified',
        ),
      );
      expect(row.length, 1);

      final shadowRows = await adapter.query(
        Statement(
          'SELECT tags FROM _electric_shadow',
        ),
      );
      expect(shadowRows.length, 2);

      final subsMeta = await satellite.getMeta<String>('subscriptions');
      final subsObj = json.decode(subsMeta) as Map<String, Object?>;
      expect(subsObj.length, 2);
    } catch (e, st) {
      fail('Reason: $e\n$st');
    }
  });

  test('a single subscribe with multiple tables with FKs', () async {
    await runMigrations();

    final qualifiedChild = const QualifiedTablename('main', 'child').toString();

    // relations must be present at subscription delivery
    client.setRelations(kTestRelations);
    client.setRelationData('parent', parentRecord);
    client.setRelationData('child', childRecord);

    final conn = await satellite.start(authConfig);
    await conn.connectionFuture;

    final ClientShapeDefinition shapeDef1 = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: 'child')],
    );
    final shapeDef2 = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: 'parent')],
    );

    satellite.relations = kTestRelations;

    final completer = Completer<void>();
    client.subscribeToSubscriptionEvents(
      (data) {
        // child is applied first
        expect(data.data[0].relation.table, 'child');
        expect(data.data[1].relation.table, 'parent');

        Timer(const Duration(milliseconds: 10), () async {
          try {
            final row = await adapter.query(
              Statement(
                'SELECT id FROM $qualifiedChild',
              ),
            );
            expect(row.length, 1);

            completer.complete();
          } catch (e) {
            completer.completeError(e);
          }
        });
      },
      (_) {},
    );

    await satellite.subscribe([shapeDef1, shapeDef2]);

    await completer.future;
  });

  test('a shape delivery that triggers garbage collection', () async {
    await runMigrations();

    const tablename = 'parent';
    final qualified = const QualifiedTablename('main', tablename).toString();

    // relations must be present at subscription delivery
    client.setRelations(kTestRelations);
    client.setRelationData(tablename, parentRecord);
    client.setRelationData('another', {});

    final conn = await satellite.start(authConfig);
    await conn.connectionFuture;

    final ClientShapeDefinition shapeDef1 = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: 'parent')],
    );
    final shapeDef2 = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: 'another')],
    );

    satellite.relations = kTestRelations;

    final ShapeSubscription(synced: synced1) =
        await satellite.subscribe([shapeDef1]);
    await synced1;
    final ShapeSubscription(synced: synced) =
        await satellite.subscribe([shapeDef2]);

    try {
      await synced;
      fail('Expected a subscription error');
    } catch (expected) {
      try {
        final row = await adapter.query(
          Statement(
            'SELECT id FROM $qualified',
          ),
        );
        expect(row.length, 0);

        final shadowRows = await adapter.query(
          Statement('SELECT tags FROM _electric_shadow'),
        );
        expect(shadowRows.length, 1);

        final subsMeta = await satellite.getMeta<String>('subscriptions');
        final subsObj = json.decode(subsMeta) as Map<String, Object?>;
        expect(subsObj, <String, Object?>{});
        expect(
          (expected as SatelliteException).message!.indexOf("table 'another'"),
          greaterThanOrEqualTo(0),
        );
      } catch (e, st) {
        fail('Reason: $e\n$st');
      }
    }
  });

  test('a subscription request failure does not clear the manager state',
      () async {
    await runMigrations();

    // relations must be present at subscription delivery
    const tablename = 'parent';
    final qualified = const QualifiedTablename('main', tablename).toString();
    client.setRelations(kTestRelations);
    client.setRelationData(tablename, parentRecord);

    final conn = await satellite.start(authConfig);
    await conn.connectionFuture;

    final shapeDef1 = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: tablename)],
    );

    final shapeDef2 = ClientShapeDefinition(
      selects: [ShapeSelect(tablename: 'failure')],
    );

    satellite.relations = kTestRelations;
    final ShapeSubscription(synced: dataReceived) =
        await satellite.subscribe([shapeDef1]);
    await dataReceived;

    try {
      final row = await adapter.query(
        Statement(
          'SELECT id FROM $qualified',
        ),
      );
      expect(row.length, 1);
    } catch (e, st) {
      fail('Reason: $e\n$st');
    }

    try {
      await satellite.subscribe([shapeDef2]);
    } catch (error) {
      expect(
        (error as SatelliteException).code,
        SatelliteErrorCode.tableNotFound,
      );
    }
  });

  test("Garbage collecting the subscription doesn't generate oplog entries",
      () async {
    await satellite.start(authConfig);
    await runMigrations();
    await adapter.run(Statement("INSERT INTO parent(id) VALUES ('1'),('2')"));
    final ts = await satellite.performSnapshot();
    await satellite.garbageCollectOplog(ts);
    expect((await satellite.getEntries(since: 0)).length, 0);

    unawaited(
      satellite.garbageCollectShapeHandler([
        ShapeDefinition(
          uuid: '',
          definition: ClientShapeDefinition(
            selects: [ShapeSelect(tablename: 'parent')],
          ),
        ),
      ]),
    );

    await satellite.performSnapshot();
    expect(await satellite.getEntries(since: 0), <OplogEntry>[]);
  });

  test('snapshots: generated oplog entries have the correct tags', () async {
    await runMigrations();

    const namespace = 'main';
    const tablename = 'parent';
    final qualified = const QualifiedTablename(namespace, tablename).toString();

    // relations must be present at subscription delivery
    client.setRelations(kTestRelations);
    client.setRelationData(tablename, parentRecord);

    final conn = await satellite.start(authConfig);
    await conn.connectionFuture;

    final shapeDef = ClientShapeDefinition(
      selects: [
        ShapeSelect(tablename: tablename),
      ],
    );

    satellite.relations = kTestRelations;
    final ShapeSubscription(:synced) = await satellite.subscribe([shapeDef]);
    await synced;

    final expectedTs = DateTime.now();
    final incoming = generateRemoteOplogEntry(
      tableInfo,
      'main',
      'parent',
      OpType.insert,
      expectedTs.millisecondsSinceEpoch,
      genEncodedTags('remote', [expectedTs]),
      newValues: {
        'id': 2,
      },
      oldValues: {},
    );
    final incomingChange = opLogEntryToChange(incoming, kTestRelations);

    await satellite.applyTransaction(
      Transaction(
        origin: 'remote',
        commitTimestamp: Int64(expectedTs.millisecondsSinceEpoch),
        changes: [incomingChange],
        lsn: [],
      ),
    );

    final row = await adapter.query(
      Statement(
        'SELECT id FROM $qualified',
      ),
    );
    expect(row.length, 2);

    final shadowRows = await adapter.query(
      Statement(
        'SELECT * FROM _electric_shadow',
      ),
    );
    expect(shadowRows.length, 2);

    expect(shadowRows[0]['namespace'], 'main');
    expect(shadowRows[0]['tablename'], 'parent');

    await adapter.run(Statement('DELETE FROM $qualified WHERE id = 2'));
    await satellite.performSnapshot();

    final oplogs = await adapter.query(
      Statement(
        'SELECT * FROM _electric_oplog',
      ),
    );
    expect(oplogs[0]['clearTags'], genEncodedTags('remote', [expectedTs]));
  });

  test('DELETE after DELETE sends clearTags', () async {
    await runMigrations();

    await satellite.setAuthState(authState);

    await adapter
        .run(Statement("INSERT INTO parent(id, value) VALUES (1,'val1')"));
    await adapter
        .run(Statement("INSERT INTO parent(id, value) VALUES (2,'val2')"));

    await adapter.run(Statement('DELETE FROM parent WHERE id=1'));

    await satellite.performSnapshot();

    await adapter.run(Statement('DELETE FROM parent WHERE id=2'));

    await satellite.performSnapshot();

    final entries = await satellite.getEntries();

    expect(entries.length, 4);

    final delete1 = entries[2];
    final delete2 = entries[3];

    expect(delete1.primaryKey, '{"id":1}');
    expect(delete1.optype, OpType.delete);
    // No tags for first delete
    expect(delete1.clearTags, '[]');

    expect(delete2.primaryKey, '{"id":2}');
    expect(delete2.optype, OpType.delete);
    // The second should have clearTags
    expect(delete2.clearTags, isNot('[]'));
  });

  test('connection backoff success', () async {
    client.disconnect();

    int numExpects = 0;

    bool retry(Object _e, int a) {
      if (a > 0) {
        numExpects++;
        return false;
      }
      return true;
    }

    satellite.connectRetryHandler = retry;

    await Future.wait<dynamic>(
      [satellite.connectWithBackoff(), satellite.initializing!.waitOn()].map(
        (f) => f.catchError((e) => numExpects++),
      ),
    );

    expect(numExpects, 3);
  });

  // check that performing snapshot doesn't throw without resetting the performing snapshot assertions
  test('(regression) performSnapshot handles exceptions gracefully', () async {
    await runMigrations();
    await satellite.setAuthState(authState);

    satellite.updateDatabaseAdapter(
      ReplaceTxDatabaseAdapter((satellite.adapter as SqliteAdapter).db),
    );

    const error = 'FAKE TRANSACTION';

    final customAdapter = satellite.adapter as ReplaceTxDatabaseAdapter;

    customAdapter.customTxFun = (_) {
      throw Exception(error);
    };

    try {
      await satellite.performSnapshot();
      fail('Should throw');
    } on Exception catch (e) {
      expect(e.toString(), 'Exception: $error');

      // Restore default tx behavior
      customAdapter.customTxFun = null;
    }

    await satellite.performSnapshot();

    // Doesn't throw
  });
}

class SlowDatabaseAdapter extends SqliteAdapter {
  SlowDatabaseAdapter(
    super.db, {
    this.delay = const Duration(milliseconds: 100),
  });

  final Duration delay;

  @override
  Future<RunResult> run(Statement statement) async {
    await Future<void>.delayed(delay);
    return super.run(statement);
  }
}

typedef _TxFun<T> = Future<T> Function(
  void Function(adp.Transaction tx, void Function(T res) setResult) f,
);

class ReplaceTxDatabaseAdapter extends SqliteAdapter {
  ReplaceTxDatabaseAdapter(
    super.db,
  );

  _TxFun<dynamic>? customTxFun;

  @override
  Future<T> transaction<T>(
    void Function(adp.Transaction tx, void Function(T res) setResult) f,
  ) {
    return customTxFun != null
        ? (customTxFun! as _TxFun<T>).call(f)
        : super.transaction(f);
  }
}
