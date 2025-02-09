import 'package:electricsql/src/electric/adapter.dart';
import 'package:electricsql/src/util/types.dart' hide Transaction;

class MockDatabaseAdapter implements DatabaseAdapter {
  @override
  Future<List<Row>> query(Statement statement) async {
    return [];
  }

  @override
  Future<RunResult> run(Statement statement) async {
    return RunResult(rowsAffected: 0);
  }

  @override
  Future<RunResult> runInTransaction(List<Statement> statements) async {
    return RunResult(rowsAffected: 0);
  }

  @override
  Future<T> transaction<T>(
    void Function(Transaction tx, void Function(T res) p1) setResult,
  ) async {
    throw UnimplementedError();
  }
}
