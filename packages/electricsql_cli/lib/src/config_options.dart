import 'package:electricsql/electricsql.dart';
import 'package:electricsql_cli/src/config.dart';
import 'package:electricsql_cli/src/util.dart';
import 'package:path/path.dart';

const minorVersion = kElectricProtocolVersion;

final configOptions = <String, ConfigOption<Object>>{
  // *** Client options ***
  'SERVICE': ConfigOption<String>(
    valueTypeName: 'url',
    doc: 'URL of the Electric service.',
    groups: ['client', 'tunnel'],
    shortForm: 's',
    defaultValueFun: (ConfigMap options) {
      final host = getConfigValue<String>('SERVICE_HOST', options);
      final port = getConfigValue<int>('HTTP_PORT', options);
      return 'http://$host:$port';
    },
    constructedDefault: 'http://{ELECTRIC_SERVICE_HOST}:{ELECTRIC_HTTP_PORT}',
  ),
  'PROXY': ConfigOption<String>(
    valueTypeName: 'url',
    doc: "URL of the Electric service's PostgreSQL proxy.",
    groups: ['client', 'proxy'],
    shortForm: 'p',
    defaultValueFun: (options) {
      final host = getConfigValue<String>('PG_PROXY_HOST', options);
      final port = parsePgProxyPort(
        getConfigValue<String>('PG_PROXY_PORT', options),
      ).port;
      const user = 'postgres';
      final password = getConfigValue<String>('PG_PROXY_PASSWORD', options);
      final dbName = getConfigValue<String>('DATABASE_NAME', options);
      final ssl = getConfigValue<bool>('DATABASE_REQUIRE_SSL', options);
      return buildDatabaseURL(
        host: host,
        port: port,
        user: user,
        password: password,
        dbName: dbName,
        ssl: ssl,
      );
    },
    constructedDefault:
        'postgresql://postgres:{ELECTRIC_PG_PROXY_PASSWORD}@{ELECTRIC_PG_PROXY_HOST}:{ELECTRIC_PG_PROXY_PORT}/{ELECTRIC_DATABASE_NAME}',
  ),
  'CLIENT_PATH': ConfigOption<String>(
    valueTypeName: 'path',
    shortForm: 'o',
    doc:
        'Path to the directory where the generated electric client code will be written.',
    groups: ['client'],
    defaultValue: join('.', 'lib', 'generated', 'electric'),
  ),
  'SERVICE_HOST': ConfigOption<String>(
    valueTypeName: 'hostname',
    doc: 'Hostname the Electric service is running on.',
    groups: ['client', 'proxy'],
    inferVal: (options) => inferServiceUrlPart('host', options: options),
    defaultValue: 'localhost',
  ),
  'PG_PROXY_HOST': ConfigOption<String>(
    valueTypeName: 'hostname',
    doc:
        'Hostname the Migration Proxy is running on. This is usually the same as, '
        'and defaults to, SERVICE_HOST. '
        ' '
        'If using the proxy-tunnel, this should be the hostname of the tunnel.',
    groups: ['client', 'proxy'],
    inferVal: (options) => inferProxyUrlPart('host', options: options),
    defaultValueFun: (options) => getConfigValue('SERVICE_HOST', options),
  ),

  // *** Postgres database connection options ***
  'WITH_POSTGRES': ConfigOption<bool>(
    doc: 'Start a PostgreSQL database along with Electric.',
    defaultValue: false,
    groups: ['database', 'electric'],
  ),
  'DATABASE_URL': ConfigOption<String>(
    doc: 'PostgreSQL connection URL for the database.',
    valueTypeName: 'url',
    shortForm: 'db',
    defaultValueFun: (options) {
      final host = getConfigValue<String>('DATABASE_HOST', options);
      final port = getConfigValue<int>('DATABASE_PORT', options);
      final user = getConfigValue<String>('DATABASE_USER', options);
      final password = getConfigValue<String>('DATABASE_PASSWORD', options);
      final dbName = getConfigValue<String>('DATABASE_NAME', options);
      return buildDatabaseURL(
        host: host,
        port: port,
        user: user,
        password: password,
        dbName: dbName,
      );
    },
    constructedDefault:
        'postgresql://{ELECTRIC_DATABASE_USER}:{ELECTRIC_DATABASE_PASSWORD}@{ELECTRIC_DATABASE_HOST}:{ELECTRIC_DATABASE_PORT}/{ELECTRIC_DATABASE_NAME}',
    groups: ['database', 'electric'],
  ),
  'DATABASE_HOST': ConfigOption<String>(
    doc: 'Hostname of the database server.',
    inferVal: (options) => inferDbUrlPart('host', options: options),
    defaultValue: 'localhost',
    groups: ['database'],
  ),
  'DATABASE_PORT': ConfigOption<int>(
    doc: 'Port number of the database server.',
    inferVal: (options) => inferDbUrlPart('port'),
    defaultValue: 5432,
    groups: ['database'],
  ),
  'DATABASE_USER': ConfigOption<String>(
    doc: 'Username to connect to the database with.',
    inferVal: (options) => inferDbUrlPart('user', options: options),
    defaultValue: 'postgres',
    groups: ['database'],
  ),
  'DATABASE_PASSWORD': ConfigOption<String>(
    doc: 'Password to connect to the database with.',
    inferVal: (options) => inferDbUrlPart('password', options: options),
    defaultValue: 'db_password',
    groups: ['database'],
  ),
  'DATABASE_NAME': ConfigOption<String>(
    doc: 'Name of the database to connect to.',
    inferVal: (options) => inferDbUrlPart('dbName', options: options),
    defaultValueFun: (_) => getAppName() ?? 'electric',
    groups: ['database', 'client', 'proxy'],
  ),

  // *** Electric options ***
  'DATABASE_REQUIRE_SSL': ConfigOption<bool>(
    defaultValue: false,
    doc: 'Require SSL for the connection to the database.',
    groups: ['electric'],
  ),
  'DATABASE_USE_IPV6': ConfigOption<bool>(
    defaultValue: false,
    doc:
        'Set if your database is only accessible over IPv6. This is the case with '
        'Fly Postgres, for example.',
    groups: ['electric'],
  ),
  'ELECTRIC_USE_IPV6': ConfigOption<bool>(
    defaultValue: false,
    doc:
        'Make Electric listen on :: instead of 0.0.0.0. On Linux this allows inbound '
        'connections over both IPv6 and IPv4. On Windows and some BSD systems inbound '
        'connections will only be accepted over IPv6 when this setting is enabled.',
    groups: ['electric'],
  ),
  'LOGICAL_PUBLISHER_HOST': ConfigOption<String>(
    valueTypeName: 'url',
    doc:
        'Host of this electric instance for the reverse connection from Postgres.',
    groups: ['electric'],
  ),
  'LOGICAL_PUBLISHER_PORT': ConfigOption<int>(
    defaultValue: 5433,
    valueTypeName: 'port',
    doc: 'Port number to use for reverse connections from Postgres.',
    groups: ['electric'],
  ),
  'HTTP_PORT': ConfigOption<int>(
    inferVal: (options) => inferServiceUrlPart('port', options: options),
    defaultValue: 5133,
    valueTypeName: 'port',
    doc:
        'Port for HTTP connections. Includes client websocket connections on /ws, and '
        'other functions on /api.',
    groups: ['electric', 'client'],
  ),
  'PG_PROXY_PORT': ConfigOption<String>(
    inferVal: (options) {
      final inferred = inferProxyUrlPart<int>('port', options: options);
      // ignore: prefer_null_aware_operators
      return inferred == null ? null : inferred.toString();
    },
    defaultValue: '65432',
    valueTypeName: 'port',
    doc: 'Port number for connections to the Postgres migration proxy.',
    groups: ['electric', 'client', 'proxy'],
  ),
  'PG_PROXY_PASSWORD': ConfigOption<String>(
    inferVal: (options) => inferProxyUrlPart('password', options: options),
    defaultValue: 'proxy_password',
    valueTypeName: 'password',
    doc:
        'Password to use when connecting to the Postgres proxy via psql or any other Postgres client.',
    groups: ['electric', 'client', 'proxy'],
  ),
  'AUTH_MODE': ConfigOption<String>(
    defaultValue: 'insecure',
    valueTypeName: 'secure | insecure',
    doc: 'Authentication mode to use to authenticate clients.',
    groups: ['electric'],
  ),
  'AUTH_JWT_ALG': ConfigOption<String>(
    valueTypeName: 'algorithm',
    doc: 'The algorithm to use for JWT verification.',
    groups: ['electric'],
  ),
  'AUTH_JWT_KEY': ConfigOption<String>(
    valueTypeName: 'key',
    doc: 'The key to use for JWT verification',
    groups: ['electric'],
  ),
  'AUTH_JWT_NAMESPACE': ConfigOption<String>(
    valueTypeName: 'namespace',
    doc:
        'This is an optional setting that specifies the location inside the token of '
        'custom claims that are specific to Electric.',
    groups: ['electric'],
  ),
  'AUTH_JWT_ISS': ConfigOption<String>(
    valueTypeName: 'iss',
    doc:
        'This optional setting allows you to specificy the "issuer" that will be matched '
        'against the iss claim extracted from auth tokens.',
    groups: ['electric'],
  ),
  'AUTH_JWT_AUD': ConfigOption<String>(
    valueTypeName: 'aud',
    doc:
        'This optional setting allows you to specificy the "audience" that will be matched '
        'against the aud claim extracted from auth tokens.',
    groups: ['electric'],
  ),
  'ELECTRIC_TELEMETRY': ConfigOption<String>(
    defaultValue: 'enabled',
    valueTypeName: 'enabled | disabled',
    doc: 'Set to "disable" to disable sending telemetry data to Electric.',
    groups: ['electric'],
  ),
  'POSTGRESQL_IMAGE': ConfigOption<String>(
    defaultValue: 'postgres:14-alpine',
    valueTypeName: 'image',
    doc: 'The Docker image to use for the PostgreSQL database.',
    groups: ['electric'],
  ),
  'ELECTRIC_IMAGE': ConfigOption<String>(
    defaultValue:
        'electricsql/electric:$minorVersion', // Latest minor version of the electric service
    valueTypeName: 'image',
    doc: 'The Docker image to use for Electric.',
    groups: ['electric'],
  ),
  'CONTAINER_NAME': ConfigOption<String>(
    valueTypeName: 'name',
    defaultValueFun: (_) => getAppName() ?? 'electric',
    doc: 'The name to use for the Docker container.',
    groups: ['electric'],
  ),
};
