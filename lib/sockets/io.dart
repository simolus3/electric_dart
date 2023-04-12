import 'dart:async';
import 'dart:typed_data';

import 'package:electric_client/sockets/sockets.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:io' as io;

class WebSocketIOFactory implements SocketFactory {
  @override
  Socket create() {
    return WebSocketIO();
  }
}

class WebSocketIO implements Socket {
  IOWebSocketChannel? _channel;
  List<StreamSubscription<dynamic>> _subscriptions = [];

  List<void Function()> _onceConnectCallbacks = [];
  List<void Function(Object error)> _onceErrorCallbacks = [];

  List<void Function(Object error)> _errorCallbacks = [];
  List<void Function()> _closeCallbacks = [];
  List<void Function(Data data)> _messageCallbacks = [];

  @override
  Socket closeAndRemoveListeners() {
    _channel?.sink.close();
    for (final cb in _closeCallbacks) {
      cb();
    }

    _subscriptions = [];
    _onceConnectCallbacks = [];
    _onceErrorCallbacks = [];
    _errorCallbacks = [];
    _closeCallbacks = [];
    _messageCallbacks = [];
    return this;
  }

  @override
  void onClose(void Function() cb) {
    _closeCallbacks.add(cb);
  }

  @override
  void onError(void Function(Object error) cb) {
    _errorCallbacks.add(cb);
  }

  @override
  void onMessage(void Function(Data data) cb) {
    _messageCallbacks.add(cb);
  }

  @override
  void onceConnect(void Function() cb) {
    _onceConnectCallbacks.add(cb);
  }

  @override
  void onceError(void Function(Object error) cb) {
    _onceErrorCallbacks.add(cb);
  }

  @override
  Socket open(ConnectionOptions opts) {
    _asyncStart(opts);
    return this;
  }

  Future<void> _asyncStart(ConnectionOptions opts) async {
    late final io.WebSocket ws;
    try {
      ws = await io.WebSocket.connect(
        opts.url,
      );
    } catch (e) {
      _notifyErrorAndCloseSocket(Exception('failed to establish connection'));
      return;
    }

    // Notify connected
    while (_onceConnectCallbacks.isNotEmpty) {
      _onceConnectCallbacks.removeLast()();
    }

    _channel = IOWebSocketChannel(ws);
    final msgSubscription = _channel!.stream //
        .listen(
      (rawData) {
        try {
          final bytes = rawData as Uint8List;

          // Notify message
          for (final cb in _messageCallbacks) {
            cb(bytes);
          }
        } catch (e) {
          _notifyErrorAndCloseSocket(e);
        }
      },
      cancelOnError: true,
      onError: (e) {
        _notifyErrorAndCloseSocket(e);
      },
    );
    _subscriptions.add(msgSubscription);
  }

  void _notifyErrorAndCloseSocket(Object e) {
    for (final cb in _errorCallbacks) {
      cb(e);
    }

    while (_onceErrorCallbacks.isNotEmpty) {
      _onceErrorCallbacks.removeLast()(e);
    }

    _channel?.sink.close();
    _channel = null;
  }

  @override
  Socket write(Data data) {
    _channel?.sink.add(data);
    return this;
  }
}
