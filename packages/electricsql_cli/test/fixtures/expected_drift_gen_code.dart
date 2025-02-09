// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: depend_on_referenced_packages, prefer_double_quotes

import 'package:drift/drift.dart';
import 'package:electricsql/drivers/drift.dart';
import 'package:electricsql/electricsql.dart';
import 'package:myapp/base_model.dart';
import 'package:myapp/custom_row_class.dart';

const kElectrifiedTables = [
  Project,
  Membership,
  Datatypes,
  Weirdnames,
  GenOptsDriftTable,
  TableWithCustomRowClass,
  Enums,
];

class Project extends Table {
  TextColumn get id => text()();

  TextColumn get name => text().nullable()();

  TextColumn get ownerId => text().named('owner_id')();

  @override
  String? get tableName => 'projects';

  @override
  Set<Column<Object>>? get primaryKey => {id};

  @override
  bool get withoutRowId => true;
}

class Membership extends Table {
  TextColumn get projectId => text().named('project_id')();

  TextColumn get userId => text().named('user_id')();

  Column<DateTime> get insertedAt =>
      customType(ElectricTypes.date).named('inserted_at')();

  @override
  String? get tableName => 'memberships';

  @override
  Set<Column<Object>>? get primaryKey => {
        projectId,
        userId,
      };

  @override
  bool get withoutRowId => true;
}

class Datatypes extends Table {
  TextColumn get cUuid => customType(ElectricTypes.uuid).named('c_uuid')();

  TextColumn get cText => text().named('c_text')();

  IntColumn get cInt => customType(ElectricTypes.int4).named('c_int')();

  IntColumn get cInt2 => customType(ElectricTypes.int2).named('c_int2')();

  IntColumn get cInt4 => customType(ElectricTypes.int4).named('c_int4')();

  IntColumn get cInt8 => customType(ElectricTypes.int8).named('c_int8')();

  RealColumn get cFloat4 =>
      customType(ElectricTypes.float4).named('c_float4')();

  RealColumn get cFloat8 =>
      customType(ElectricTypes.float8).named('c_float8')();

  BoolColumn get cBool => boolean().named('c_bool')();

  Column<DateTime> get cDate =>
      customType(ElectricTypes.date).named('c_date')();

  Column<DateTime> get cTime =>
      customType(ElectricTypes.time).named('c_time')();

  Column<DateTime> get cTimestamp =>
      customType(ElectricTypes.timestamp).named('c_timestamp')();

  Column<DateTime> get cTimestamptz =>
      customType(ElectricTypes.timestampTZ).named('c_timestamptz')();

  Column<Object> get cJson => customType(ElectricTypes.json).named('c_json')();

  Column<Object> get cJsonb =>
      customType(ElectricTypes.jsonb).named('c_jsonb')();

  @override
  String? get tableName => 'datatypes';

  @override
  Set<Column<Object>>? get primaryKey => {cUuid};

  @override
  bool get withoutRowId => true;
}

class Weirdnames extends Table {
  TextColumn get cUuid => customType(ElectricTypes.uuid).named('c_uuid')();

  TextColumn get val => text().named('1val')();

  TextColumn get text$ => text().named('text')();

  Column<Object> get braces => customType(ElectricTypes.json)();

  Column<DbInteger> get int$ =>
      customType(ElectricEnumTypes.integer).named('int').nullable()();

  @override
  String? get tableName => 'weirdnames';

  @override
  Set<Column<Object>>? get primaryKey => {cUuid};

  @override
  bool get withoutRowId => true;
}

@DataClassName(
  'MyDataClassName',
  extending: BaseModel,
)
class GenOptsDriftTable extends Table {
  @JsonKey('my_id')
  IntColumn get myIdCol => customType(ElectricTypes.int4).named('id')();

  TextColumn get value => text()();

  Column<DateTime> get timestamp => customType(ElectricTypes.timestampTZ)
      .clientDefault(() => DateTime.now())();

  @override
  String? get tableName => 'GenOpts';

  @override
  bool get withoutRowId => true;
}

@UseRowClass(
  MyCustomRowClass,
  constructor: 'fromDb',
)
class TableWithCustomRowClass extends Table {
  IntColumn get id => customType(ElectricTypes.int4)();

  TextColumn get value => text()();

  RealColumn get d => customType(ElectricTypes.float4)();

  @override
  bool get withoutRowId => true;
}

class Enums extends Table {
  TextColumn get id => text()();

  Column<DbColor> get c => customType(ElectricEnumTypes.color).nullable()();

  @override
  String? get tableName => 'enums';

  @override
  Set<Column<Object>>? get primaryKey => {id};

  @override
  bool get withoutRowId => true;
}

// ------------------------------ ENUMS ------------------------------

/// Dart enum for Postgres enum "color"
enum DbColor { red, green, blue }

/// Dart enum for Postgres enum "integer"
enum DbInteger {
  int$,
  bool$,
  double$,
  float,
  someVal,
  value$1,
  value$2,
  value$3,
  rdValue,
  weIRdStuFf
}

/// Dart enum for Postgres enum "snake_case_enum"
enum DbSnakeCaseEnum { v1, v2 }

/// Codecs for Electric enums
class ElectricEnumCodecs {
  /// Codec for Dart enum "color"
  static final color = ElectricEnumCodec<DbColor>(
    dartEnumToPgEnum: <DbColor, String>{
      DbColor.red: 'RED',
      DbColor.green: 'GREEN',
      DbColor.blue: 'BLUE',
    },
    values: DbColor.values,
  );

  /// Codec for Dart enum "integer"
  static final integer = ElectricEnumCodec<DbInteger>(
    dartEnumToPgEnum: <DbInteger, String>{
      DbInteger.int$: 'int',
      DbInteger.bool$: 'Bool',
      DbInteger.double$: 'DOUBLE',
      DbInteger.float: '2Float',
      DbInteger.someVal: '_some_val',
      DbInteger.value$1: '01 value',
      DbInteger.value$2: '2 value',
      DbInteger.value$3: '2Value',
      DbInteger.rdValue: '3rd value',
      DbInteger.weIRdStuFf: 'WeIRd*Stu(ff)',
    },
    values: DbInteger.values,
  );

  /// Codec for Dart enum "snake_case_enum"
  static final snakeCaseEnum = ElectricEnumCodec<DbSnakeCaseEnum>(
    dartEnumToPgEnum: <DbSnakeCaseEnum, String>{
      DbSnakeCaseEnum.v1: 'v1',
      DbSnakeCaseEnum.v2: 'v2',
    },
    values: DbSnakeCaseEnum.values,
  );
}

/// Drift custom types for Electric enums
class ElectricEnumTypes {
  /// Codec for Dart enum "color"
  static final color = CustomElectricTypeGeneric(
    codec: ElectricEnumCodecs.color,
    typeName: 'color',
  );

  /// Codec for Dart enum "integer"
  static final integer = CustomElectricTypeGeneric(
    codec: ElectricEnumCodecs.integer,
    typeName: 'integer',
  );

  /// Codec for Dart enum "snake_case_enum"
  static final snakeCaseEnum = CustomElectricTypeGeneric(
    codec: ElectricEnumCodecs.snakeCaseEnum,
    typeName: 'snake_case_enum',
  );
}
