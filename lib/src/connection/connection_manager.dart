library connection_manager;


import 'dart:io';
import 'dart:isolate';
import 'dart:scalarlist';
import 'package:logging/logging.dart';
import '../protocol/ldap_protocol.dart';

import '../filter.dart';
import '../ldap_exception.dart';
import '../ldap_result.dart';
import '../ldap_connection.dart';


/**
 * Holds a pending LDAP operation. We expect to see
 * a response to this operation come back.
 *
 * todo: Do we implement timeouts?
 */
class PendingOp {

  Stopwatch _stopwatch = new Stopwatch()..start();

  LDAPMessage message;
  final Completer  completer = new Completer();

  PendingOp(this.message);

  String toString() => "PendingOp m=${message}";
}


/**
 * Manages the state of the LDAP connection
 */

class ConnectionManager {

  //LDAPConnection _connection;

  Queue<PendingOp> _outgoingMessageQueue = new Queue<PendingOp>();
  Queue<PendingOp> _pendingMessages = new Queue<PendingOp>();

  static const DISCONNECTED = 0;
  static const CONNECTING = 1;
  static const CONNECTED = 2;
  //static const BINDING = 3;
  //static const BOUND = 4;
  static const CLOSING = 6;
  static const CLOSED = 7;


  int _connectionState = CLOSED;
  Socket _socket;

  int _nextMessageId = 1;

  LDAPConnection _connection;

  ConnectionManager(this._connection);

  Function onError;

  connect() {
    if( _connectionState == CONNECTED )
      return;

    logger.finest("Creating socket to ${_connection.host}:${_connection.port}");
    _connectionState = CONNECTING;
    _socket = new Socket(_connection.host,_connection.port);

    _socket.onConnect = _connectHandler;
    _socket.onError = _errorHandler;
  }


  Future process(RequestOp rop) {
    var m = new LDAPMessage(++_nextMessageId, rop);

    var op = new PendingOp(m);
    _outgoingMessageQueue.add( op);
    sendPendingMessage();
    return op.completer.future;
  }

  sendPendingMessage() {
    //logger.fine("Send pending messages");
    if( _connectionState == CONNECTING ) {
      logger.finest("Not connected or ready. Yielding");
      return;
    }

    while( _messagesToSend() ) {
      var op = _outgoingMessageQueue.removeFirst();
      _sendMessage(op);
    }
  }

  /**
   * Return TRUE if there are messages waiting to be sent.
   *
   * Note that BIND is synchronous (as per LDAP spec) - so if there is a pending BIND
   * we must wait to send more messages until the BIND response comes back
   */
  bool _messagesToSend() {
    if( _outgoingMessageQueue.isEmpty)
      return false;
    if( ! _pendingMessages.isEmpty ) {
      var m = _pendingMessages.first.message;
      if( m.protocolTag == BIND_REQUEST)
        return false;
    }
    return true;
  }

  _sendMessage(PendingOp op) {
    logger.fine("Sending message ${op.message}");
    var l = op.message.toBytes();
    var b_read = _socket.writeList(l, 0,l.length);
    // todo: check length of bytes read
    _pendingMessages.add(op);
  }


  _connectHandler() {
    logger.fine("Connected");
    _connectionState = CONNECTED;

    _socket.onData = _dataHandler;

    sendPendingMessage();
  }

  /**
   * Check for pending ops..
   *
   * Close the LDAP connection.
   *
   * Pending operations will be allowed to finish, unless immediate = true
   */

  close({bool immediate:false}) {
    _connectionState = CLOSING;
    if( immediate ) {
      _doClose();
    }
    else {
      new Timer.repeating(1000, (Timer t) {
        if( _tryClose() )
          t.cancel();
      });
    }
  }

  bool _tryClose() {
    if( _pendingMessages.isEmpty && _outgoingMessageQueue.isEmpty) {
      _doClose();
      return true;
    }
    logger.finest("close waiting for queue to drain");
    print("pending $_pendingMessages  out=$_outgoingMessageQueue");
    return false;
  }

  _doClose() {
    _socket.close();
    _connectionState = CLOSED;
  }


  /// Handle incoming messages
  _dataHandler() {
    int available = _socket.available();
    while( available > 0 ) {
      var buffer = new Uint8List(available);

      var count = _socket.readList(buffer,0, buffer.length);
      logger.finest("read ${count} bytes");
      //var s = listToHexString(buffer);
      //logger.finest("Bytes read = ${s}");


      // handle the message.
      // there could be more than one message here
      // so we keep track of how many bytes each message is
      // and continue parsing until we consume all of the bytes.
      var tempBuf = buffer;
      int bcount = tempBuf.length;


      while( bcount > 0) {
        int  bytesRead = _handleMessage(tempBuf);
        bcount = bcount - bytesRead;
        if(bcount > 0 )
          tempBuf = new Uint8List.view( tempBuf.asByteArray(bytesRead,bcount));
      }

      sendPendingMessage(); // see if there are any pending messages
      available = _socket.available();
    }
    logger.finest("No more data, exiting _dataHandler");
  }

  /// todo: what if search results come back out of order? Possible?
  ///
  int _handleMessage(Uint8List buffer) {
    var m = new LDAPMessage.fromBytes(buffer);
    logger.fine("Recieved LDAP message ${m} byte length=${m.messageLength}");

    var rop = ResponseHandler.handleResponse(m);

    if( rop is SearchResultEntry ) {
      handleSearchOp(rop);
    }
    else if( rop is SearchResultDone ) {
      logger.fine("Finished Search Results = ${searchResults}");
      searchResults.ldapResult = rop.ldapResult;
      var op = _pendingMessages.removeFirst();
      op.completer.complete(searchResults);
      searchResults = new SearchResult(); // create new for next search
    }

    else {
      var op = _pendingMessages.removeFirst();
      op.completer.complete(rop.ldapResult);
    }
    return m.messageLength;
  }

  SearchResult searchResults = new SearchResult();

  void handleSearchOp(SearchResultEntry r) {
    logger.fine("Adding result ${r} ");
    searchResults.add(r.searchEntry);
  }

  _errorHandler(e) {
    logger.severe("LDAP Error ${e}");
    var ex = new LDAPException(e.toString());
    if( _connection.onError != null) {
      _connection.onError(ex);
    }
    else {
      logger.warning("No error handler set for LDAPConnection");
      throw ex;
    }
  }

}