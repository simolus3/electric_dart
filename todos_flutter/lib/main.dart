import 'dart:async';

import 'package:electricsql/util.dart' show genUUID;
import 'package:electricsql/electricsql.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_svg/svg.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:todos_electrified/database/database.dart';
import 'package:todos_electrified/database/drift/connection/connection.dart'
    as impl;
import 'package:todos_electrified/electric.dart';
import 'package:todos_electrified/init.dart';
import 'package:todos_electrified/theme.dart';
import 'package:todos_electrified/todos.dart';
import 'package:animated_emoji/animated_emoji.dart';

const kListId = "LIST-ID-SAMPLE";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(_Entrypoint());
}

StateProvider<bool> dbDeletedProvider = StateProvider((ref) => false);

class _Entrypoint extends HookWidget {
  @override
  Widget build(BuildContext context) {
    final initDataVN = useState<InitData?>(null);

    final initData = initDataVN.value;

    useEffect(() {
      // Cleanup resources on app unmount
      return () {
        () async {
          if (initData != null) {
            await initData.electricClient.close();
            await initData.todosDb.todosRepo.close();
            print("Everything closed");
          }
        }();
      };
    }, [initData]);

    if (initData == null) {
      // This will initialize the app and will update the initData ValueNotifer
      return InitAppLoader(initDataVN: initDataVN);
    }

    // Database and Electric are ready
    return ProviderScope(
      overrides: [
        todosDatabaseProvider.overrideWithValue(initData.todosDb),
        electricClientProvider.overrideWithValue(initData.electricClient),
        connectivityStateControllerProvider.overrideWith(
          (ref) => initData.connectivityStateController,
        ),
      ],
      child: const MyApp(),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Todos Electrified',
      theme: ThemeData.from(
        useMaterial3: true,
        colorScheme: kElectricColorScheme,
      ),
      home: Consumer(
        builder: (context, ref, _) {
          final dbDeleted = ref.watch(dbDeletedProvider);

          if (dbDeleted) {
            return const _DeleteDbScreen();
          }

          return const MyHomePage();
        },
      ),
    );
  }
}

class MyHomePage extends HookConsumerWidget {
  const MyHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todosAV = ref.watch(todosProvider);

    final electricClient = ref.watch(electricClientProvider);
    useEffect(() {
      electricClient.syncTables(["todo", "todolist"]);
      return null;
    }, []);

    return Scaffold(
      appBar: AppBar(
        leading: const Center(
          child: FlutterLogo(
            size: 35,
          ),
        ),
        title: Row(
          children: [
            const Text("todos", style: TextStyle(fontSize: 30)),
            const SizedBox(width: 20),
            Icon(getIconForPlatform()),
            const SizedBox(width: 5),
            Text(getPlatformName()),
            const SizedBox(width: 10),
            const AnimatedEmoji(
              AnimatedEmojis.electricity,
              size: 24,
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          const SizedBox(height: 10),
          const ConnectivityButton(),
          const SizedBox(height: 10),
          Expanded(
            child: todosAV.when(
              data: (todos) {
                return _TodosLoaded(todos: todos);
              },
              error: (e, st) {
                return Center(child: Text(e.toString()));
              },
              loading: () => const Center(child: CircularProgressIndicator()),
            ),
          ),
          Align(
            alignment: Alignment.center,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                children: [
                  const Text(
                    "Unofficial Dart client running on top of\nthe sync service powered by",
                    textAlign: TextAlign.center,
                  ),
                  SvgPicture.asset(
                    "assets/electric.svg",
                    height: 40,
                  ),
                ],
              ),
            ),
          ),
          const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.all(8.0),
              child: _DeleteDbButton(),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeleteDbButton extends ConsumerWidget {
  const _DeleteDbButton();

  @override
  Widget build(BuildContext context, ref) {
    return TextButton.icon(
      style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.error),
      onPressed: () async {
        ref.read(dbDeletedProvider.notifier).update((state) => true);

        final todosDb = ref.read(todosDatabaseProvider);
        await todosDb.todosRepo.close();

        await impl.deleteTodosDbFile();
      },
      icon: const Icon(Symbols.delete),
      label: const Text("Delete local database"),
    );
  }
}

class ConnectivityButton extends HookConsumerWidget {
  const ConnectivityButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectivityState = ref.watch(
      connectivityStateControllerProvider
          .select((value) => value.connectivityState),
    );

    final theme = Theme.of(context);

    final ({Color color, IconData icon}) iconInfo = switch (connectivityState) {
      ConnectivityState.available => (
          icon: Symbols.wifi,
          color: Colors.orangeAccent
        ),
      ConnectivityState.connected => (
          icon: Symbols.wifi,
          color: theme.colorScheme.primary
        ),
      ConnectivityState.disconnected => (
          icon: Symbols.wifi_off,
          color: theme.colorScheme.error
        ),
    };

    final String label = switch (connectivityState) {
      ConnectivityState.available => "Available",
      ConnectivityState.connected => "Connected",
      ConnectivityState.disconnected => "Disconnected",
    };

    return ElevatedButton.icon(
      onPressed: () async {
        final connectivityStateController =
            ref.read(connectivityStateControllerProvider);
        connectivityStateController.toggleConnectivityState();
      },
      style: ElevatedButton.styleFrom(foregroundColor: iconInfo.color),
      icon: Icon(iconInfo.icon),
      label: Text(label),
    );
  }
}

class _TodosLoaded extends HookConsumerWidget {
  const _TodosLoaded({required this.todos});

  final List<Todo> todos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textController = useTextEditingController();

    return Align(
      alignment: Alignment.topCenter,
      child: Card(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 500),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: textController,
                  decoration: const InputDecoration(
                    hintText: "What needs to be done?",
                  ),
                  onEditingComplete: () async {
                    final text = textController.text;
                    if (text.trim().isEmpty) {
                      // clear focus
                      FocusScope.of(context).requestFocus(FocusNode());
                      return;
                    }
                    print("done");
                    final db = ref.read(todosDatabaseProvider);
                    await db.insertTodo(
                      Todo(
                        id: genUUID(),
                        listId: kListId,
                        text: textController.text,
                        editedAt: DateTime.now(),
                        completed: false,
                      ),
                    );

                    textController.clear();
                  },
                ),
                const SizedBox(
                  height: 15,
                ),
                Flexible(
                  child: todos.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Text("No todos yet"),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          separatorBuilder: (context, i) => const Divider(
                            height: 0,
                          ),
                          itemBuilder: (context, i) {
                            return TodoTile(todo: todos[i]);
                          },
                          itemCount: todos.length,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TodoTile extends ConsumerWidget {
  final Todo todo;
  const TodoTile({super.key, required this.todo});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: IconButton(
        onPressed: () async {
          final db = ref.read(todosDatabaseProvider);
          await db.updateTodo(todo.copyWith(completed: !todo.completed));
        },
        icon: todo.completed
            ? Icon(
                Symbols.check_circle_outline,
                color: Theme.of(context).colorScheme.primary,
              )
            : const Icon(Symbols.circle),
      ),
      title: Text(
        todo.text ?? "",
        style: TextStyle(
          decoration: todo.completed ? TextDecoration.lineThrough : null,
          color: todo.completed ? Colors.grey : null,
        ),
      ),
      subtitle: Text(
        "Last edited: ${DateFormat.yMMMd().add_jm().format(todo.editedAt)}",
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: IconButton(
        onPressed: () async {
          final db = ref.read(todosDatabaseProvider);
          await db.removeTodo(todo.id);
        },
        icon: const Icon(Symbols.delete),
      ),
    );
  }
}

class _DeleteDbScreen extends StatelessWidget {
  const _DeleteDbScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('Local database has been deleted, please restart the app'),
      ),
    );
  }
}

IconData getIconForPlatform() {
  if (kIsWeb) {
    return MdiIcons.web;
  } else if (defaultTargetPlatform == TargetPlatform.android) {
    return MdiIcons.android;
  } else if (defaultTargetPlatform == TargetPlatform.iOS) {
    return MdiIcons.appleIos;
  } else if (defaultTargetPlatform == TargetPlatform.fuchsia) {
    return MdiIcons.google;
  } else if (defaultTargetPlatform == TargetPlatform.linux) {
    return MdiIcons.linux;
  } else if (defaultTargetPlatform == TargetPlatform.windows) {
    return MdiIcons.microsoftWindows;
  } else if (defaultTargetPlatform == TargetPlatform.macOS) {
    return MdiIcons.apple;
  } else {
    return Icons.help_outline;
  }
}

String getPlatformName() {
  if (kIsWeb) {
    return "Web";
  } else if (defaultTargetPlatform == TargetPlatform.android) {
    return "Android";
  } else if (defaultTargetPlatform == TargetPlatform.iOS) {
    return "iOS";
  } else if (defaultTargetPlatform == TargetPlatform.fuchsia) {
    return "Fuchsia";
  } else if (defaultTargetPlatform == TargetPlatform.linux) {
    return "Linux";
  } else if (defaultTargetPlatform == TargetPlatform.windows) {
    return "Windows";
  } else if (defaultTargetPlatform == TargetPlatform.macOS) {
    return "macOS";
  } else {
    return "Unknown";
  }
}
