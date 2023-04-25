import 'dart:async';
import 'dart:io';

import 'package:electric_client/auth/mock.dart';
import 'package:electric_client/electric/adapter.dart' hide Transaction;
import 'package:electric_client/electric/sqlite3_adapter.dart' hide Transaction;
import 'package:electric_client/migrators/bundle.dart';
import 'package:electric_client/migrators/migrators.dart';
import 'package:electric_client/notifiers/mock.dart';
import 'package:electric_client/notifiers/notifiers.dart';
import 'package:electric_client/satellite/config.dart';
import 'package:electric_client/satellite/mock.dart';
import 'package:electric_client/satellite/oplog.dart';
import 'package:electric_client/satellite/process.dart';
import 'package:electric_client/util/common.dart';
import 'package:electric_client/util/random.dart';
import 'package:electric_client/util/tablename.dart';
import 'package:electric_client/util/types.dart' hide Change;
import 'package:electric_client/util/types.dart' as t;
import 'package:fixnum/fixnum.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../support/migrations.dart';
import '../support/satellite_helpers.dart';
import '../util/io.dart';
import '../util/sqlite_errors.dart';
import 'common.dart';

late Database db;
late DatabaseAdapter adapter;
late Migrator migrator;
late MockNotifier notifier;
late TableInfo tableInfo;
late DateTime timestamp;
late SatelliteProcess satellite;
late MockSatelliteClient client;
late String dbName;

Future<void> runMigrations() async {
  await migrator.up();
}

final opts = kSatelliteDefaults.copyWith(
  minSnapshotWindow: const Duration(milliseconds: 40),
  pollingInterval: const Duration(milliseconds: 200),
);

final satelliteConfig = SatelliteConfig(
  app: 'test',
  env: 'default',
);

void main() {
  setUp(() async {
    await Directory(".tmp").create(recursive: true);

    dbName = '.tmp/test-${randomValue()}.db';
    db = sqlite3.open(dbName);
    adapter = SqliteAdapter(db);
    migrator = BundleMigrator(adapter: adapter, migrations: kTestMigrations);
    notifier = MockNotifier(dbName);
    client = MockSatelliteClient();
    final console = MockConsoleClient();
    satellite = SatelliteProcess(
      dbName: dbName,
      adapter: adapter,
      migrator: migrator,
      notifier: notifier,
      client: client,
      console: console,
      config: satelliteConfig,
      opts: opts,
    );

    tableInfo = initTableInfo();
    timestamp = DateTime.now();
  });

  tearDown(() async {
    await removeFile(dbName);
    await removeFile("$dbName-journal");

    await satellite.stop();
  });

  test('start creates system tables', () async {
    await satellite.start(null);

    const sql = "select name from sqlite_master where type = 'table'";
    final rows = await adapter.query(Statement(sql));
    final names = rows.map((row) => row['name']! as String).toList();

    expect(names, contains('_electric_oplog'));
  });

  test('load metadata', () async {
    await runMigrations();

    final meta = await loadSatelliteMetaTable(adapter);
    expect(meta, {
      "compensations": 0,
      "lastAckdRowId": '0',
      "lastSentRowId": '0',
      "lsn": '',
      "clientId": '',
      "token":
          'INITIAL_INVALID_TOKEN', // we need some value here for auth service
      "refreshToken": '',
    });
  });

  test('set persistent client id', () async {
    await satellite.start(null);
    final clientId1 = satellite.authState!.clientId;
    await satellite.stop();

    await satellite.start(null);

    final clientId2 = satellite.authState!.clientId;

    expect(clientId1, clientId2);

    await Future<void>.delayed(const Duration(milliseconds: 500));
  });

  test('connect saves new token', () async {
    await runMigrations();

    final initToken = await satellite.getMeta('token');
    final connectionWrapper = await satellite.start(null);
    await connectionWrapper.connectionFuture;
    final receivedToken = await satellite.getMeta('token');

    expect(initToken, isNot(receivedToken));
  });

  test('cannot UPDATE primary key', () async {
    await runMigrations();

    await adapter.run(Statement("INSERT INTO parent(id) VALUES ('1'),('2')"));

    await expectLater(
      adapter.run(Statement("UPDATE parent SET id='3' WHERE id = '1'")),
      throwsA(
        isA<SqliteException>().having(
          (SqliteException e) => e.extendedResultCode,
          "code",
          SqliteErrors.SQLITE_CONSTRAINT_TRIGGER,
        ),
      ),
    );
  });

  test('snapshot works', () async {
    await runMigrations();
    await satellite.setAuthState(null);

    await adapter.run(Statement("INSERT INTO parent(id) VALUES ('1'),('2')"));

    final snapshotTimestamp = await satellite.performSnapshot();

    final clientId = satellite.authState!.clientId;
    final shadowTags = encodeTags([generateTag(clientId, snapshotTimestamp)]);

    final shadowRows = await adapter.query(
      Statement("SELECT tags FROM _electric_shadow"),
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

  test('starting and stopping the process works', () async {
    await runMigrations();

    await adapter.run(Statement("INSERT INTO parent(id) VALUES ('1'),('2')"));

    await satellite.start(null);

    await Future<void>.delayed(opts.pollingInterval);

    expect(notifier.notifications.length, 1);

    await adapter.run(Statement("INSERT INTO parent(id) VALUES ('3'),('4')"));
    await Future<void>.delayed(opts.pollingInterval);

    expect(notifier.notifications.length, 2);

    await satellite.stop();
    await adapter.run(Statement("INSERT INTO parent(id) VALUES ('5'),('6')"));
    await Future<void>.delayed(opts.pollingInterval);

    expect(notifier.notifications.length, 2);

    await satellite.start(null);
    await Future<void>.delayed(Duration.zero);

    expect(notifier.notifications.length, 3);
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
    await adapter.run(Statement("DELETE FROM parent WHERE id=1"));
    await adapter.run(Statement("INSERT INTO parent(id) VALUES (1)"));

    await satellite.setAuthState(null);
    await satellite.performSnapshot();
    final entries = await satellite.getEntries();
    final clientId = satellite.authState!.clientId;

    final merged = localOperationsToTableChanges(entries, (DateTime timestamp) {
      return generateTag(clientId, timestamp);
    });
    final opLogTableChange = merged['main.parent']!['1']!;
    final keyChanges = opLogTableChange.oplogEntryChanges;
    final resultingValue = keyChanges.changes["value"]!.value;
    expect(resultingValue, null);
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
        generateTag('remote', DateTime.fromMillisecondsSinceEpoch(incomingTs))
      ]),
      newValues: {
        "id": 1,
        "value": 'incoming',
      },
      oldValues: {},
    );
    await adapter.run(
      Statement(
        "INSERT INTO parent(id, value, other) VALUES (1, 'local', 1)",
      ),
    );

    await satellite.setAuthState(null);
    final localTime = await satellite.performSnapshot();
    final clientId = satellite.authState!.clientId;

    final local = await satellite.getEntries();
    final localTimestamp =
        DateTime.parse(local[0].timestamp).millisecondsSinceEpoch;
    final merged = satellite.mergeEntries(clientId, local, 'remote', [
      incomingEntry,
    ]);
    final item = merged['main.parent']!['1'];

    expect(
      item,
      ShadowEntryChanges(
        namespace: 'main',
        tablename: 'parent',
        primaryKeyCols: {"id": 1},
        optype: ChangesOpType.upsert,
        changes: {
          "id": OplogColumnChange(1, localTimestamp),
          "value": OplogColumnChange('local', localTimestamp),
          "other": OplogColumnChange(1, localTimestamp),
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

    await satellite.setAuthState();
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
      genEncodedTags("remote", [incomingTs]),
      newValues: {
        "id": 1,
        "value": 'incoming',
      },
      oldValues: {},
    );

    final merged = satellite.mergeEntries(clientId, local, 'remote', [
      incomingEntry,
    ]);
    final item = merged['main.parent']!['1'];

    expect(
      item,
      ShadowEntryChanges(
        namespace: 'main',
        tablename: 'parent',
        primaryKeyCols: {"id": 1},
        optype: ChangesOpType.upsert,
        changes: {
          "id": OplogColumnChange(1, incomingTs.millisecondsSinceEpoch),
          "value":
              OplogColumnChange('incoming', incomingTs.millisecondsSinceEpoch),
          "other": OplogColumnChange(1, localTimestamp.millisecondsSinceEpoch),
        },
        tags: [
          generateTag(clientId, localTimestamp),
          generateTag('remote', incomingTs),
        ],
      ),
    );
  });

  test('apply does not add anything to oplog', () async {
    await runMigrations();
    await adapter.run(
      Statement(
        "INSERT INTO parent(id, value, other) VALUES (1, 'local', null)",
      ),
    );

    await satellite.setAuthState();
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
        "id": 1,
        "value": 'incoming',
        "other": 1,
      },
      oldValues: {},
    );

    await satellite.apply([incomingEntry], 'remote', []);
    await satellite.performSnapshot();

    const sql = 'SELECT * from parent WHERE id=1';
    final row = (await adapter.query(Statement(sql)))[0];
    expect(row['value']! as String, 'incoming');
    expect(row['other']! as int, 1);

    final localEntries = await satellite.getEntries();
    final shadowEntry =
        await satellite.getOplogShadowEntry(oplog: localEntries[0]);

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
        "id": 1,
        "value": 'incoming',
        "otherValue": 1,
      },
      oldValues: {},
    );
    await satellite.setAuthState();
    await satellite.apply([incomingEntry], 'remote', []);

    const sql = 'SELECT * from parent WHERE id=1';
    final rows = await adapter.query(Statement(sql));
    final shadowEntries = await satellite.getOplogShadowEntry();

    expect(shadowEntries, isEmpty);
    expect(rows, isEmpty);
  });

  test('apply empty incoming', () async {
    await runMigrations();

    await satellite.setAuthState();

    // TODO(dart): Is this an empty incoming? When can it happen?
    await satellite.apply([], "", []);
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
        "id": 1234,
        "value": 'incoming',
        "other": null,
      },
      oldValues: {},
    );

    await satellite.setAuthState();
    await satellite.apply([incomingEntry], 'remote', []);

    const sql = "SELECT * from main.parent WHERE value='incoming'";
    final rows = await adapter.query(Statement(sql));

    expect(rows[0]["other"], null);
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
        "id": 1234,
        "value": 'incoming',
      },
      oldValues: {},
    );

    await satellite.setAuthState();
    await satellite.apply([incomingEntry], 'remote', []);

    const sql = "SELECT * from main.parent WHERE value='incoming'";
    final rows = await adapter.query(Statement(sql));

    expect(rows[0]["other"], 0);
  });

  test('INSERT wins over DELETE and restored deleted values', () async {
    await runMigrations();
    await satellite.setAuthState();
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
          "id": 1,
          "other": 1,
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
          "id": 1,
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
          "id": 1,
          "value": 'local',
          "other": null,
        },
      ),
    ];

    final merged = satellite.mergeEntries(clientId, local, 'remote', incoming);
    final item = merged['main.parent']!['1'];

    expect(
      item,
      ShadowEntryChanges(
        namespace: 'main',
        tablename: 'parent',
        primaryKeyCols: {"id": 1},
        optype: ChangesOpType.upsert,
        changes: {
          "id": OplogColumnChange(1, incomingTs.millisecondsSinceEpoch),
          "value": OplogColumnChange('local', localTs.millisecondsSinceEpoch),
          "other": OplogColumnChange(1, incomingTs.millisecondsSinceEpoch),
        },
        tags: [
          generateTag(clientId, localTs),
          generateTag('remote', incomingTs),
        ],
      ),
    );
  });

  test('merge incoming with empty local', () async {
    await runMigrations();
    await satellite.setAuthState();
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
          "id": 1,
        },
        oldValues: {},
      ),
    ];

    final local = <OplogEntry>[];
    final merged = satellite.mergeEntries(clientId, local, 'remote', incoming);
    final item = merged['main.parent']!['1'];

    expect(
      item,
      ShadowEntryChanges(
        namespace: 'main',
        tablename: 'parent',
        primaryKeyCols: {"id": 1},
        optype: ChangesOpType.upsert,
        changes: {
          "id": OplogColumnChange(1, incomingTs.millisecondsSinceEpoch),
        },
        tags: [generateTag('remote', incomingTs)],
      ),
    );
  });

  test('advance oplog cursor', () async {
    await runMigrations();

    // fake current propagated rowId
    satellite.lastSentRowId = 2;

    // Get tablenames.
    final oplogTablename = opts.oplogTable.tablename;
    final metaTablename = opts.metaTable.tablename;

    // Insert a couple of rows.
    await adapter
        .run(Statement("INSERT INTO main.parent(id) VALUES ('1'),('2')"));

    // We have two rows in the oplog.
    var rows = await adapter.query(
      Statement(
        "SELECT count(rowid) as num_rows FROM $oplogTablename",
      ),
    );
    expect(rows[0]["num_rows"], 2);

    // Ack.
    await satellite.ack(2, true);

    // NOTE: The oplog is not clean! This is a current design decision to clear
    // oplog only when receiving transaction that originated from Satellite in the
    // first place.
    rows = await adapter.query(
      Statement(
        "SELECT count(rowid) as num_rows FROM $oplogTablename",
      ),
    );
    expect(rows[0]["num_rows"], 2);

    // Verify the meta.
    rows = await adapter.query(
      Statement(
        "SELECT value FROM $metaTablename WHERE key = 'lastAckdRowId'",
      ),
    );
    expect(rows[0]["value"], '2');
  });

  test('compensations: referential integrity is enforced', () async {
    await runMigrations();

    await adapter.run(Statement("PRAGMA foreign_keys = ON"));
    await satellite.setMeta('compensations', 0);
    await adapter.run(
      Statement(
        "INSERT INTO main.parent(id, value) VALUES (1, '1')",
      ),
    );

    await expectLater(
      adapter
          .run(Statement("INSERT INTO main.child(id, parent) VALUES (1, 2)")),
      throwsA(
        isA<SqliteException>().having(
          (SqliteException e) => e.extendedResultCode,
          "code",
          SqliteErrors.SQLITE_CONSTRAINT_FOREIGNKEY,
        ),
      ),
    );
  });

  test('compensations: incoming operation breaks referential integrity',
      () async {
    await runMigrations();

    await adapter.run(Statement("PRAGMA foreign_keys = ON;"));
    await satellite.setMeta('compensations', 0);
    await satellite.setAuthState();

    final incoming = [
      generateLocalOplogEntry(
        tableInfo,
        'main',
        'child',
        OpType.insert,
        timestamp.millisecondsSinceEpoch,
        genEncodedTags('remote', [timestamp]),
        newValues: {
          "id": 1,
          "parent": 1,
        },
      ),
    ];

    await satellite.setAuthState();
    await expectLater(
      satellite.apply(incoming, 'remote', []),
      throwsA(
        isA<SqliteException>().having(
          (SqliteException e) => e.extendedResultCode,
          "code",
          SqliteErrors.SQLITE_CONSTRAINT_FOREIGNKEY,
        ),
      ),
    );
  });

  test(
      'compensations: incoming operations accepted if restore referential integrity',
      () async {
    await runMigrations();

    await adapter.run(Statement("PRAGMA foreign_keys = ON;"));
    await satellite.setMeta('compensations', 0);
    await satellite.setAuthState();
    final clientId = satellite.authState!.clientId;

    final incoming = [
      generateRemoteOplogEntry(
        tableInfo,
        'main',
        'child',
        OpType.insert,
        timestamp.millisecondsSinceEpoch,
        genEncodedTags(clientId, [timestamp]),
        newValues: {
          "id": 1,
          "parent": 1,
        },
      ),
      generateRemoteOplogEntry(
        tableInfo,
        'main',
        'parent',
        OpType.insert,
        timestamp.millisecondsSinceEpoch,
        genEncodedTags(clientId, [timestamp]),
        newValues: {
          "id": 1,
        },
      ),
    ];

    await adapter.run(
      Statement(
        "INSERT INTO main.parent(id, value) VALUES (1, '1')",
      ),
    );
    await adapter.run(Statement("DELETE FROM main.parent WHERE id=1"));

    await satellite.setAuthState();
    await satellite.performSnapshot();
    await satellite.apply(incoming, 'remote', []);
    final rows = await adapter.query(
      Statement(
        "SELECT * from main.parent WHERE id=1",
      ),
    );

    // Not only does the parent exist.
    expect(rows.length, 1);

    // But it's also recreated with deleted values.
    expect(rows[0]["value"], '1');
  });

  test('compensations: using triggers with flag 0', () async {
    await runMigrations();

    await adapter.run(Statement("PRAGMA foreign_keys = ON"));
    await satellite.setMeta('compensations', 0);
    satellite.lastSentRowId = 1;

    await adapter.run(
      Statement("INSERT INTO main.parent(id, value) VALUES (1, '1')"),
    );
    await satellite.setAuthState();
    await satellite.performSnapshot();
    await satellite.ack(1, true);

    await adapter
        .run(Statement("INSERT INTO main.child(id, parent) VALUES (1, 1)"));
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
          "id": 1,
        },
      ),
    ];

    await expectLater(
      satellite.apply(incoming, 'remote', []),
      throwsA(
        isA<SqliteException>().having(
          (SqliteException e) => e.extendedResultCode,
          "code",
          SqliteErrors.SQLITE_CONSTRAINT_FOREIGNKEY,
        ),
      ),
    );
  });

  test('compensations: using triggers with flag 1', () async {
    await runMigrations();

    await adapter.run(Statement("PRAGMA foreign_keys = ON"));
    await satellite.setMeta('compensations', 1);
    satellite.lastSentRowId = 1;

    await adapter.run(
      Statement("INSERT INTO main.parent(id, value) VALUES (1, '1')"),
    );
    await satellite.setAuthState();
    await satellite.performSnapshot();
    await satellite.ack(1, true);

    await adapter
        .run(Statement("INSERT INTO main.child(id, parent) VALUES (1, 1)"));
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
          "id": 1,
        },
      ),
    ];

    // TODO(dart) No expectations?
    await satellite.apply(incoming, "", []);
  });

  test('get oplogEntries from transaction', () async {
    await runMigrations();

    final relations = await satellite.getLocalRelations();

    final transaction = Transaction(
      lsn: kDefaultLogPos,
      commitTimestamp: Int64.ZERO,
      changes: [
        t.Change(
          relation: relations["parent"]!,
          type: ChangeType.insert,
          record: {"id": 0},
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

    final expected = <Transaction>[
      Transaction(
        lsn: numberToBytes(2),
        commitTimestamp: Int64.ZERO,
        changes: [
          t.Change(
            relation: kTestRelations["parent"]!,
            type: ChangeType.insert,
            record: {"id": 0},
            oldRecord: null,
            tags: [],
          ),
          t.Change(
            relation: kTestRelations["parent"]!,
            type: ChangeType.insert,
            record: {"id": 1},
            oldRecord: {"id": 1},
            tags: [],
          ),
        ],
      ),
      Transaction(
        lsn: numberToBytes(3),
        commitTimestamp: Int64(1000),
        changes: [
          t.Change(
            relation: kTestRelations["parent"]!,
            type: ChangeType.insert,
            record: {"id": 2},
            oldRecord: null,
            tags: [],
          ),
        ],
      ),
    ];

    final opLog = toTransactions(opLogEntries, kTestRelations);
    expect(opLog, expected);
  });

  test('rowid acks updates meta', () async {
    await runMigrations();
    await satellite.start(null);

    final lsn1 = numberToBytes(1);
    client.emit('ack_lsn', AckLsnEvent(lsn1, AckType.localSend));

    final lsn = await satellite.getMeta('lastSentRowId');
    expect(lsn, '1');
  });

  test('handling connectivity state change stops queueing operations',
      () async {
    await runMigrations();
    await satellite.start(null);

    await adapter.run(
      Statement(
        "INSERT INTO parent(id, value, other) VALUES (1, 'local', 1)",
      ),
    );

    await satellite.performSnapshot();

    final lsn = await satellite.getMeta('lastSentRowId');
    expect(lsn, '1');

    final completer = Completer<void>();
    Timer(const Duration(milliseconds: 100), () async {
      final lsn = await satellite.getMeta('lastAckdRowId');
      expect(lsn, '1');
      completer.complete();
    });

    await completer.future;

    await satellite.connectivityStateChange(ConnectivityState.disconnected);

    await adapter.run(
      Statement(
        "INSERT INTO parent(id, value, other) VALUES (2, 'local', 1)",
      ),
    );

    await satellite.performSnapshot();

    final lsn1 = await satellite.getMeta('lastSentRowId');
    expect(lsn1, '1');

    await satellite.connectivityStateChange(ConnectivityState.connected);

    // TODO(dart) This test is not passing in TS when awaiting the 200 ms
    /* await Future<void>.delayed(const Duration(milliseconds: 200));
    final lsn2 = await satellite.getMeta('lastSentRowId');
    expect(lsn2, '2'); */
  });

  test(
      'garbage collection is triggered when transaction from the same origin is replicated',
      () async {
    await runMigrations();
    await satellite.start(null);

    final clientId = satellite.authState!.clientId;

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

    var lsn = await satellite.getMeta('lastSentRowId');
    expect(lsn, '0');

    await satellite.performSnapshot();

    lsn = await satellite.getMeta('lastSentRowId');
    expect(lsn, '2');
    lsn = await satellite.getMeta('lastAckdRowId');

    final old_oplog = await satellite.getEntries();
    final transactions = toTransactions(old_oplog, kTestRelations);
    transactions[0].origin = clientId;

    await satellite.applyTransaction(transactions[0]);
    final new_oplog = await satellite.getEntries();
    expect(new_oplog, isEmpty);
  });
}
// Document if we support CASCADE https://www.sqlite.org/foreignkeys.html
// Document that we do not maintian the order of execution of incoming operations and therefore we defer foreign key checks to the outermost commit
