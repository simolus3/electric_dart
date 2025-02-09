import 'dart:async';
import 'dart:convert';

import 'package:electricsql/src/auth/auth.dart';
import 'package:electricsql/src/client/model/schema.dart';
import 'package:electricsql/src/config/config.dart';
import 'package:electricsql/src/electric/adapter.dart' hide Transaction;
import 'package:electricsql/src/migrators/migrators.dart';
import 'package:electricsql/src/notifiers/notifiers.dart';
import 'package:electricsql/src/proto/satellite.pb.dart';
import 'package:electricsql/src/satellite/config.dart';
import 'package:electricsql/src/satellite/oplog.dart';
import 'package:electricsql/src/satellite/registry.dart';
import 'package:electricsql/src/satellite/satellite.dart';
import 'package:electricsql/src/satellite/shapes/types.dart';
import 'package:electricsql/src/sockets/sockets.dart';
import 'package:electricsql/src/util/async_event_emitter.dart';
import 'package:electricsql/src/util/common.dart';
import 'package:electricsql/src/util/proto.dart';
import 'package:electricsql/src/util/types.dart';
import 'package:meta/meta.dart';

typedef DataRecord = Record;

const kMockBehindWindowLsn = 42;
const kMockInternalError = 27;

class MockSatelliteProcess implements Satellite {
  @override
  final DbName dbName;
  @override
  final DatabaseAdapter adapter;
  @override
  final Migrator migrator;
  @override
  final Notifier notifier;
  final SocketFactory socketFactory;
  final SatelliteOpts opts;

  @override
  ConnectivityState? connectivityState;

  MockSatelliteProcess({
    required this.dbName,
    required this.adapter,
    required this.migrator,
    required this.notifier,
    required this.socketFactory,
    required this.opts,
  });

  @override
  Future<ShapeSubscription> subscribe(
    List<ClientShapeDefinition> shapeDefinitions,
  ) async {
    return ShapeSubscription(synced: Future.value());
  }

  @override
  Future<void> unsubscribe(String shapeUuid) async {
    throw UnimplementedError();
  }

  @override
  Future<ConnectionWrapper> start(AuthConfig authConfig) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));

    return ConnectionWrapper(
      connectionFuture: Future.value(),
    );
  }

  @override
  Future<void> stop({bool? shutdown}) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

@visibleForTesting
class MockRegistry extends BaseRegistry {
  bool _shouldFailToStart = false;

  void setShouldFailToStart(bool shouldFail) {
    _shouldFailToStart = shouldFail;
  }

  @override
  Future<Satellite> startProcess({
    required DbName dbName,
    required DBSchema dbDescription,
    required DatabaseAdapter adapter,
    required Migrator migrator,
    required Notifier notifier,
    required SocketFactory socketFactory,
    required HydratedConfig config,
    SatelliteOverrides? overrides,
  }) async {
    if (_shouldFailToStart) {
      throw Exception('Failed to start satellite process');
    }

    var effectiveOpts = kSatelliteDefaults;
    if (overrides != null) {
      effectiveOpts = effectiveOpts.copyWithOverrides(overrides);
    }

    final satellite = MockSatelliteProcess(
      dbName: dbName,
      adapter: adapter,
      migrator: migrator,
      notifier: notifier,
      socketFactory: socketFactory,
      opts: effectiveOpts,
    );
    await satellite.start(config.auth);

    return satellite;
  }
}

class MockSatelliteClient extends AsyncEventEmitter implements Client {
  bool isDown = false;
  bool replicating = false;
  bool disconnected = true;
  List<int>? inboundAck = kDefaultLogPos;

  List<int> outboundSent = kDefaultLogPos;

  // to clear any pending timeouts
  List<Timer> timeouts = [];

  RelationsCache relations = {};
  void Function(Relation relation)? relationsCb;
  TransactionCallback? transactionsCb;

  Map<String, List<DataRecord>> relationData = {};

  bool deliverFirst = false;

  void setRelations(RelationsCache relations) {
    this.relations = relations;

    final _relationsCb = relationsCb;
    if (_relationsCb != null) {
      for (final rel in relations.values) {
        _relationsCb(rel);
      }
    }
  }

  void setRelationData(String tablename, DataRecord record) {
    if (!relationData.containsKey(tablename)) {
      relationData[tablename] = [];
    }
    final data = relationData[tablename]!;

    data.add(record);
  }

  void enableDeliverFirst() {
    deliverFirst = true;
  }

  @override
  Future<SubscribeResponse> subscribe(
    String subscriptionId,
    List<ShapeRequest> shapes,
  ) {
    final data = <InitialDataChange>[];
    final Map<String, String> shapeReqToUuid = {};

    for (final shape in shapes) {
      for (final ShapeSelect(:tablename) in shape.definition.selects) {
        if (tablename == 'failure' || tablename == 'Items') {
          return Future.value(
            SubscribeResponse(
              subscriptionId: subscriptionId,
              error: SatelliteException(SatelliteErrorCode.tableNotFound, null),
            ),
          );
        }
        if (tablename == 'another' || tablename == 'User') {
          return Future(() {
            sendErrorAfterTimeout(subscriptionId, 1);
            return SubscribeResponse(
              subscriptionId: subscriptionId,
              error: null,
            );
          });
        } else {
          shapeReqToUuid[shape.requestId] = uuid();
          final List<DataRecord> records = relationData[tablename] ?? [];

          for (final record in records) {
            final dataChange = InitialDataChange(
              relation: relations[tablename]!,
              record: record,
              tags: [generateTag('remote', DateTime.now())],
            );
            data.add(dataChange);
          }
        }
      }
    }

    return Future(() {
      void emitDelivered() => enqueueEmit(
            kSubscriptionDelivered,
            SubscriptionData(
              subscriptionId: subscriptionId,
              lsn: base64.decode('MTIz'), // base64.encode("123")
              data: data,
              shapeReqToUuid: shapeReqToUuid,
            ),
          );

      final completer = Completer<SubscribeResponse>();
      void resolve() {
        completer.complete(
          SubscribeResponse(
            subscriptionId: subscriptionId,
            error: null,
          ),
        );
      }

      if (deliverFirst) {
        // When the `deliverFirst` flag is set,
        // we deliver the subscription before resolving the promise.
        emitDelivered();
        Timer(const Duration(milliseconds: 1), resolve);
      } else {
        // Otherwise, we resolve the promise before delivering the subscription.
        Timer(const Duration(milliseconds: 1), emitDelivered);
        resolve();
      }

      return completer.future;
    });
  }

  @override
  Future<UnsubscribeResponse> unsubscribe(List<String> _subIds) async {
    return UnsubscribeResponse();
  }

  @override
  SubscriptionEventListeners subscribeToSubscriptionEvents(
    SubscriptionDeliveredCallback successCallback,
    SubscriptionErrorCallback errorCallback,
  ) {
    final removeSuccessListener = _on(kSubscriptionDelivered, successCallback);
    final removeErrorListener = _on(kSubscriptionError, errorCallback);

    return SubscriptionEventListeners(
      removeSuccessListener: removeSuccessListener,
      removeErrorListener: removeErrorListener,
    );
  }

  @override
  void unsubscribeToSubscriptionEvents(SubscriptionEventListeners listeners) {
    listeners.removeSuccessListener();
    listeners.removeErrorListener();
  }

  @override
  void Function() subscribeToError(ErrorCallback callback) {
    return _on('error', callback);
  }

  @override
  bool isConnected() {
    return !disconnected;
  }

  @override
  void shutdown() {
    isDown = true;
  }

  @override
  LSN getLastSentLsn() {
    return outboundSent;
  }

  @override
  Future<void> connect({
    bool Function(Object error, int attempt)? retryHandler,
  }) async {
    if (isDown) {
      throw SatelliteException(
        SatelliteErrorCode.unexpectedState,
        'FAKE DOWN',
      );
    }

    disconnected = false;
  }

  @override
  void disconnect() {
    disconnected = true;
    for (final t in timeouts) {
      t.cancel();
    }
    return;
  }

  @override
  Future<AuthResponse> authenticate(
    AuthState _authState,
  ) async {
    return AuthResponse(
      null,
      null,
    );
  }

  @override
  Future<StartReplicationResponse> startReplication(
    LSN? lsn,
    String? schemaVersion,
    List<String>? subscriptionIds,
    //_resume?: boolean | undefined
  ) {
    replicating = true;
    inboundAck = lsn;

    final t = Timer(
      const Duration(milliseconds: 100),
      () => enqueueEmit<void>('outbound_started', null),
    );
    timeouts.add(t);

    if (lsn != null && bytesToNumber(lsn) == kMockBehindWindowLsn) {
      return Future.value(
        StartReplicationResponse(
          error: SatelliteException(
            SatelliteErrorCode.behindWindow,
            'MOCK BEHIND_WINDOW_LSN ERROR',
          ),
        ),
      );
    }

    if (lsn != null && bytesToNumber(lsn) == kMockInternalError) {
      return Future.value(
        StartReplicationResponse(
          error: SatelliteException(
            SatelliteErrorCode.internal,
            'MOCK INTERNAL_ERROR',
          ),
        ),
      );
    }

    return Future.value(StartReplicationResponse());
  }

  @override
  Future<StopReplicationResponse> stopReplication() {
    replicating = false;
    return Future.value(StopReplicationResponse());
  }

  @override
  void Function() subscribeToRelations(
    void Function(Relation relation) callback,
  ) {
    relationsCb = callback;

    return () {
      relationsCb = null;
    };
  }

  @override
  void Function() subscribeToTransactions(
    Future<void> Function(Transaction transaction) callback,
  ) {
    transactionsCb = callback;

    return () {
      transactionsCb = null;
    };
  }

  @override
  void enqueueTransaction(
    DataTransaction transaction,
  ) {
    outboundSent = transaction.lsn;
  }

  @override
  void Function() subscribeToOutboundStarted(
    OutboundStartedCallback callback,
  ) {
    return _on<void>('outbound_started', callback);
  }

  void sendErrorAfterTimeout(String subscriptionId, int timeoutMillis) {
    Timer(Duration(milliseconds: timeoutMillis), () {
      final satSubsError = SatSubsDataError(
        code: SatSubsDataError_Code.SHAPE_DELIVERY_ERROR,
        message: 'there were shape errors',
        subscriptionId: subscriptionId,
        shapeRequestError: [
          SatSubsDataError_ShapeReqError(
            code: SatSubsDataError_ShapeReqError_Code.SHAPE_SIZE_LIMIT_EXCEEDED,
            message:
                "Requested shape for table 'another' exceeds the maximum allowed shape size",
          ),
        ],
      );

      final satError = subsDataErrorToSatelliteError(satSubsError);
      enqueueEmit(
        kSubscriptionError,
        SubscriptionErrorData(subscriptionId: subscriptionId, error: satError),
      );
    });
  }

  void Function() _on<T>(
    String eventName,
    FutureOr<void> Function(T) callback,
  ) {
    FutureOr<void> wrapper(dynamic data) {
      return callback(data as T);
    }

    on(eventName, wrapper);

    return () {
      removeListener(eventName, wrapper);
    };
  }
}
