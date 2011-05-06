/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Geary.Imap.ClientSession : Object, Geary.Account {
    // Need this because delegates with targets cannot be stored in ADTs.
    private class CommandCallback {
        public SourceFunc callback;
        
        public CommandCallback(SourceFunc callback) {
            this.callback = callback;
        }
    }
    
    private class AsyncCommandResponse {
        public CommandResponse? cmd_response { get; private set; }
        public Object? user { get; private set; }
        public Error? err { get; private set; }
        
        public AsyncCommandResponse(CommandResponse? cmd_response, Object? user, Error? err) {
            this.cmd_response = cmd_response;
            this.user = user;
            this.err = err;
        }
    }
    
    // Many of the async commands go through the FSM, and this is used to pass state around until
    // the multiple transitions are completed
    private class AsyncParams : Object {
        public Cancellable? cancellable;
        public SourceFunc cb;
        public CommandResponse? cmd_response = null;
        public Error? err = null;
        public bool do_yield = false;
        
        public AsyncParams(Cancellable? cancellable, SourceFunc cb) {
            this.cancellable = cancellable;
            this.cb = cb;
        }
    }
    
    private class LoginParams : AsyncParams {
        public string user;
        public string pass;
        
        public LoginParams(string user, string pass, Cancellable? cancellable, SourceFunc cb) {
            base (cancellable, cb);
            
            this.user = user;
            this.pass = pass;
        }
    }
    
    private class SelectParams : AsyncParams {
        public string mailbox;
        public bool is_select;
        
        public SelectParams(string mailbox, bool is_select, Cancellable? cancellable, SourceFunc cb) {
            base (cancellable, cb);
            
            this.mailbox = mailbox;
            this.is_select = is_select;
        }
    }
    
    private enum State {
        // canonical IMAP session states
        DISCONNECTED,
        NOAUTH,
        AUTHORIZED,
        SELECTED,
        LOGGED_OUT,
        
        // transitional states
        CONNECTING,
        AUTHORIZING,
        SELECTING,
        CLOSING_MAILBOX,
        LOGGING_OUT,
        DISCONNECTING,
        
        // terminal state
        BROKEN,
        
        COUNT
    }
    
    private static string state_to_string(uint state) {
        return ((State) state).to_string();
    }
    
    private enum Event {
        // user-initated events
        CONNECT,
        LOGIN,
        SELECT,
        CLOSE_MAILBOX,
        LOGOUT,
        DISCONNECT,
        
        // async-response events
        CONNECTED,
        CONNECT_DENIED,
        LOGIN_SUCCESS,
        LOGIN_FAILED,
        SELECTED,
        SELECT_FAILED,
        CLOSED_MAILBOX,
        CLOSE_MAILBOX_FAILED,
        LOGOUT_SUCCESS,
        LOGOUT_FAILED,
        DISCONNECTED,
        
        // I/O errors
        RECV_ERROR,
        SEND_ERROR,
        
        COUNT;
    }
    
    private static string event_to_string(uint event) {
        return ((Event) event).to_string();
    }
    
    private static Geary.State.MachineDescriptor machine_desc = new Geary.State.MachineDescriptor(
        "Geary.Imap.ClientSession", State.DISCONNECTED, State.COUNT, Event.COUNT,
        state_to_string, event_to_string);
    
    private string server;
    private uint default_port;
    private Geary.State.Machine fsm;
    private ClientConnection? cx = null;
    private Mailbox? current_mailbox = null;
    private Gee.Queue<CommandCallback> cb_queue = new Gee.LinkedList<CommandCallback>();
    private Gee.Queue<CommandResponse> cmd_response_queue = new Gee.LinkedList<CommandResponse>();
    private CommandResponse current_cmd_response = new CommandResponse();

    // state used only during connect and disconnect
    private bool awaiting_connect_response = false;
    private ServerData? connect_response = null;
    private AsyncParams? connect_params = null;
    private AsyncParams? disconnect_params = null;
    
    public ClientSession(string server, uint default_port) {
        this.server = server;
        this.default_port = default_port;
        
        Geary.State.Mapping[] mappings = {
            new Geary.State.Mapping(State.DISCONNECTED, Event.CONNECT, on_connect),
            new Geary.State.Mapping(State.DISCONNECTED, Event.LOGIN, on_early_command),
            new Geary.State.Mapping(State.DISCONNECTED, Event.SELECT, on_early_command),
            new Geary.State.Mapping(State.DISCONNECTED, Event.CLOSE_MAILBOX, on_early_command),
            new Geary.State.Mapping(State.DISCONNECTED, Event.LOGOUT, on_early_command),
            new Geary.State.Mapping(State.DISCONNECTED, Event.DISCONNECT, Geary.State.nop),
            
            new Geary.State.Mapping(State.CONNECTING, Event.CONNECT, Geary.State.nop),
            new Geary.State.Mapping(State.CONNECTING, Event.LOGIN, on_early_command),
            new Geary.State.Mapping(State.CONNECTING, Event.SELECT, on_early_command),
            new Geary.State.Mapping(State.CONNECTING, Event.CLOSE_MAILBOX, on_early_command),
            new Geary.State.Mapping(State.CONNECTING, Event.LOGOUT, on_early_command),
            new Geary.State.Mapping(State.CONNECTING, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.CONNECTING, Event.CONNECTED, on_connected),
            new Geary.State.Mapping(State.CONNECTING, Event.CONNECT_DENIED, on_connect_denied),
            new Geary.State.Mapping(State.CONNECTING, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.CONNECTING, Event.RECV_ERROR, on_recv_error),
            
            new Geary.State.Mapping(State.NOAUTH, Event.LOGIN, on_login),
            new Geary.State.Mapping(State.NOAUTH, Event.SELECT, on_unauthenticated),
            new Geary.State.Mapping(State.NOAUTH, Event.CLOSE_MAILBOX, on_unauthenticated),
            new Geary.State.Mapping(State.NOAUTH, Event.LOGOUT, on_logout),
            new Geary.State.Mapping(State.NOAUTH, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.NOAUTH, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.NOAUTH, Event.RECV_ERROR, on_recv_error),
            
            new Geary.State.Mapping(State.AUTHORIZING, Event.LOGIN, Geary.State.nop),
            new Geary.State.Mapping(State.AUTHORIZING, Event.SELECT, on_unauthenticated),
            new Geary.State.Mapping(State.AUTHORIZING, Event.CLOSE_MAILBOX, on_unauthenticated),
            new Geary.State.Mapping(State.AUTHORIZING, Event.LOGOUT, on_logout),
            new Geary.State.Mapping(State.AUTHORIZING, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.AUTHORIZING, Event.LOGIN_SUCCESS, on_login_success),
            new Geary.State.Mapping(State.AUTHORIZING, Event.LOGIN_FAILED, on_login_failed),
            new Geary.State.Mapping(State.AUTHORIZING, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.AUTHORIZING, Event.RECV_ERROR, on_recv_error),
            
            new Geary.State.Mapping(State.AUTHORIZED, Event.SELECT, on_select),
            new Geary.State.Mapping(State.AUTHORIZED, Event.CLOSE_MAILBOX, Geary.State.nop),
            new Geary.State.Mapping(State.AUTHORIZED, Event.LOGOUT, on_logout),
            new Geary.State.Mapping(State.AUTHORIZED, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.AUTHORIZED, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.AUTHORIZED, Event.RECV_ERROR, on_recv_error),
            
            // TODO: technically, if the user selects while selecting, we should handle this
            // in some fashion
            new Geary.State.Mapping(State.SELECTING, Event.SELECT, Geary.State.nop),
            new Geary.State.Mapping(State.SELECTING, Event.CLOSE_MAILBOX, on_close_mailbox),
            new Geary.State.Mapping(State.SELECTING, Event.LOGOUT, on_logout),
            new Geary.State.Mapping(State.SELECTING, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.SELECTING, Event.SELECTED, on_selected),
            new Geary.State.Mapping(State.SELECTING, Event.SELECT_FAILED, on_select_failed),
            new Geary.State.Mapping(State.SELECTING, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.SELECTING, Event.RECV_ERROR, on_recv_error),
            
            new Geary.State.Mapping(State.SELECTED, Event.SELECT, on_select),
            new Geary.State.Mapping(State.SELECTED, Event.CLOSE_MAILBOX, on_close_mailbox),
            new Geary.State.Mapping(State.SELECTED, Event.LOGOUT, on_logout),
            new Geary.State.Mapping(State.SELECTED, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.SELECTED, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.SELECTED, Event.RECV_ERROR, on_recv_error),
            
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.CLOSED_MAILBOX, on_closed_mailbox),
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.CLOSE_MAILBOX_FAILED, on_close_mailbox_failed),
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.LOGOUT, on_logout),
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.RECV_ERROR, on_recv_error),
            
            new Geary.State.Mapping(State.LOGGING_OUT, Event.CONNECT, on_late_command),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.LOGIN, on_late_command),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.SELECT, on_late_command),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.CLOSE_MAILBOX, on_late_command),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.LOGOUT, Geary.State.nop),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.LOGOUT_SUCCESS, on_logged_out),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.LOGOUT_FAILED, Geary.State.nop),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.RECV_ERROR, Geary.State.nop),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.SEND_ERROR, on_send_error),
            
            new Geary.State.Mapping(State.LOGGED_OUT, Event.CONNECT, on_late_command),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.LOGIN, on_late_command),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.SELECT, on_late_command),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.CLOSE_MAILBOX, on_late_command),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.LOGOUT, on_late_command),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.RECV_ERROR, Geary.State.nop),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.SEND_ERROR, on_send_error),
            
            new Geary.State.Mapping(State.DISCONNECTING, Event.CONNECT, on_late_command),
            new Geary.State.Mapping(State.DISCONNECTING, Event.LOGIN, on_late_command),
            new Geary.State.Mapping(State.DISCONNECTING, Event.SELECT, on_late_command),
            new Geary.State.Mapping(State.DISCONNECTING, Event.CLOSE_MAILBOX, on_late_command),
            new Geary.State.Mapping(State.DISCONNECTING, Event.LOGOUT, on_late_command),
            new Geary.State.Mapping(State.DISCONNECTING, Event.DISCONNECTED, on_disconnected),
            new Geary.State.Mapping(State.DISCONNECTING, Event.SEND_ERROR, Geary.State.nop),
            new Geary.State.Mapping(State.DISCONNECTING, Event.RECV_ERROR, Geary.State.nop),
            
            new Geary.State.Mapping(State.BROKEN, Event.CONNECT, on_late_command),
            new Geary.State.Mapping(State.BROKEN, Event.LOGIN, on_late_command),
            new Geary.State.Mapping(State.BROKEN, Event.SELECT, on_late_command),
            new Geary.State.Mapping(State.BROKEN, Event.CLOSE_MAILBOX, on_late_command),
            new Geary.State.Mapping(State.BROKEN, Event.LOGOUT, on_late_command),
            new Geary.State.Mapping(State.BROKEN, Event.DISCONNECT, Geary.State.nop)
        };
        
        fsm = new Geary.State.Machine(machine_desc, mappings, on_ignored_transition);
        fsm.set_logging(true);
    }
    
    public Tag? generate_tag() {
        return (cx != null) ? cx.generate_tag() : null;
    }
    
    //
    // connect
    //
    
    public async void connect_async(Cancellable? cancellable = null) throws Error {
        AsyncParams params = new AsyncParams(cancellable, connect_async.callback);
        fsm.issue(Event.CONNECT, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
        
        debug("Connected to %s: %s", to_full_string(), connect_response.to_string());
    }
    
    private uint on_connect(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        assert(connect_params == null);
        connect_params = (AsyncParams) object;
        
        assert(cx == null);
        cx = new ClientConnection(server, ClientConnection.DEFAULT_PORT_TLS);
        cx.connected.connect(on_network_connected);
        cx.disconnected.connect(on_network_disconnected);
        cx.sent_command.connect(on_network_sent_command);
        cx.received_status_response.connect(on_received_status_response);
        cx.received_server_data.connect(on_received_server_data);
        cx.received_bad_response.connect(on_received_bad_response);
        cx.receive_failure.connect(on_receive_failed);
        
        cx.connect_async.begin(connect_params.cancellable, on_connect_completed);
        
        connect_params.do_yield = true;
        
        return State.CONNECTING;
    }
    
    private void on_connect_completed(Object? source, AsyncResult result) {
        assert(connect_params != null);
        
        try {
            cx.connect_async.end(result);
        } catch (Error err) {
            fsm.issue(Event.SEND_ERROR, null, null, err);
            connect_params.err = err;
            
            Idle.add(connect_params.cb);
            connect_params = null;
            
            return;
        }
        
        // wait for the initial greeting from the server
        cb_queue.offer(new CommandCallback(on_connect_response_received));
        awaiting_connect_response = true;
    }
    
    private bool on_connect_response_received() {
        assert(connect_params != null);
        assert(connect_response != null);
        
        // initial greeting from server is an untagged response where the first parameter is a
        // status code
        try {
            StringParameter status_param = (StringParameter) connect_response.get_as(
                1, typeof(StringParameter));
            issue_status(Status.from_parameter(status_param), Event.CONNECTED, Event.CONNECT_DENIED,
                connect_response);
        } catch (ImapError imap_err) {
            connect_params.err = imap_err;
            fsm.issue(Event.CONNECT_DENIED);
        }
        
        Idle.add(connect_params.cb);
        connect_params = null;
        
        return false;
    }
    
    private uint on_connected(uint state, uint event, void *user) {
        return State.NOAUTH;
    }
    
    private uint on_connect_denied(uint state, uint event, void *user) {
        debug("Connection to %s denied by server", to_full_string());
        
        return State.BROKEN;
    }
    
    //
    // login
    //
    
    public async void login_async(string user, string pass, Cancellable? cancellable = null) throws Error {
        LoginParams params = new LoginParams(user, pass, cancellable, login_async.callback);
        fsm.issue(Event.LOGIN, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
        
        debug("Logged in to %s: %s", to_full_string(), params.cmd_response.to_string());
    }
    
    private uint on_login(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        LoginParams params = (LoginParams) object;
        
        issue_command_async.begin(new LoginCommand(cx.generate_tag(), params.user, params.pass),
            params, params.cancellable, on_login_completed);
        
        params.do_yield = true;
        
        return State.AUTHORIZING;
    }
    
    private void on_login_completed(Object? source, AsyncResult result) {
        generic_issue_command_completed(result, Event.LOGIN_SUCCESS, Event.LOGIN_FAILED);
    }
    
    private uint on_login_success(uint state, uint event, void *user) {
        return State.AUTHORIZED;
    }
    
    private uint on_login_failed(uint state, uint event, void *user) {
        debug("Login to %s failed", to_full_string());
        
        return State.NOAUTH;
    }
    
    //
    // select/examine
    //
    
    public async Mailbox select_async(string mailbox, Cancellable? cancellable = null) throws Error {
        return yield select_examine_async(mailbox, true, cancellable);
    }
    
    public async Mailbox examine_async(string mailbox, Cancellable? cancellable = null) throws Error {
        return yield select_examine_async(mailbox, false, cancellable);
    }
    
    private async Mailbox select_examine_async(string mailbox, bool is_select, Cancellable? cancellable)
        throws Error {
        SelectParams params = new SelectParams(mailbox, is_select, cancellable,
            select_examine_async.callback);
        fsm.issue(Event.SELECT, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
        
        assert(current_mailbox != null);
        
        return current_mailbox;
    }
    
    private uint on_select(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        SelectParams params = (SelectParams) object;
        
        if (current_mailbox != null && current_mailbox.name == params.mailbox)
            return state;
        
        // TODO: Currently don't handle situation where one mailbox is selected and another is
        // asked for without closing
        assert(current_mailbox == null);
        
        Command cmd;
        if (params.is_select)
            cmd = new SelectCommand(cx.generate_tag(), params.mailbox);
        else
            cmd = new ExamineCommand(cx.generate_tag(), params.mailbox);
        issue_command_async.begin(cmd, params, params.cancellable, on_select_completed);
        
        params.do_yield = true;
        
        return State.SELECTING;
    }
    
    private void on_select_completed(Object? source, AsyncResult result) {
        generic_issue_command_completed(result, Event.SELECTED, Event.SELECT_FAILED);
    }
    
    private uint on_selected(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        SelectParams params = (SelectParams) object;
        
        assert(current_mailbox == null);
        current_mailbox = new Mailbox(params.mailbox, this);
        
        return State.SELECTED;
    }
    
    private uint on_select_failed(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        SelectParams params = (SelectParams) object;
        
        params.err = new ImapError.COMMAND_FAILED("Unable to select mailbox \"%s\": %s",
            params.mailbox, params.cmd_response.to_string());
        
        return State.AUTHORIZED;
    }
    
    //
    // close mailbox
    //
    
    public async void close_mailbox_async(Cancellable? cancellable = null) throws Error {
        AsyncParams params = new AsyncParams(cancellable, close_mailbox_async.callback);
        fsm.issue(Event.CLOSE_MAILBOX, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
        
        debug("Closed mailbox");
    }
    
    private uint on_close_mailbox(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        AsyncParams params = (AsyncParams) object;
        
        issue_command_async.begin(new CloseCommand(cx.generate_tag()), params, params.cancellable,
            on_close_mailbox_completed);
        
        params.do_yield = true;
        
        return State.CLOSING_MAILBOX;
    }
    
    private void on_close_mailbox_completed(Object? source, AsyncResult result) {
        generic_issue_command_completed(result, Event.CLOSED_MAILBOX, Event.CLOSE_MAILBOX_FAILED);
    }
    
    private uint on_closed_mailbox(uint state, uint event) {
        return State.AUTHORIZED;
    }
    
    private uint on_close_mailbox_failed(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        AsyncParams params = (AsyncParams) object;
        params.err = new ImapError.COMMAND_FAILED("Unable to close mailbox \"%s\": %s",
            current_mailbox.name, params.cmd_response.to_string());
        
        return State.SELECTED;
    }
    
    //
    // logout
    //
    
    public async void logout_async(Cancellable? cancellable = null) throws Error {
        AsyncParams params = new AsyncParams(cancellable, logout_async.callback);
        fsm.issue(Event.LOGOUT, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
        
        debug("Logged out of %s: %s", to_string(), params.cmd_response.to_string());
    }
    
    private uint on_logout(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        AsyncParams params = (AsyncParams) object;
        
        issue_command_async.begin(new LogoutCommand(cx.generate_tag()), params, params.cancellable,
            on_logout_completed);
        
        params.do_yield = true;
        
        return State.LOGGING_OUT;
    }
    
    private void on_logout_completed(Object? source, AsyncResult result) {
        generic_issue_command_completed(result, Event.LOGOUT_SUCCESS, Event.LOGOUT_FAILED);
    }
    
    private uint on_logged_out(uint state, uint event, void *user) {
        return State.LOGGED_OUT;
    }
    
    //
    // disconnect
    //
    
    public async void disconnect_async(Cancellable? cancellable = null) throws Error {
        AsyncParams params = new AsyncParams(cancellable, disconnect_async.callback);
        fsm.issue(Event.DISCONNECT, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
    }
    
    private uint on_disconnect(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        assert(disconnect_params == null);
        disconnect_params = (AsyncParams) object;
        
        cx.disconnect_async.begin(disconnect_params.cancellable, on_disconnect_completed);
        
        disconnect_params.do_yield = true;
        
        return State.DISCONNECTING;
    }
    
    private void on_disconnect_completed(Object? source, AsyncResult result) {
        assert(disconnect_params != null);
        
        try {
            cx.disconnect_async.end(result);
            fsm.issue(Event.DISCONNECTED);
        } catch (Error err) {
            fsm.issue(Event.SEND_ERROR, null, null, err);
            disconnect_params.err = err;
        }
        
        Idle.add(disconnect_params.cb);
        disconnect_params = null;
    }
    
    private uint on_disconnected(uint state, uint event) {
        cx = null;
        
        // although we could go to the DISCONNECTED state, that implies the object can be reused ...
        // while possible, that requires all state (not just the FSM) be reset at this point, and
        // it just seems simpler and less buggy to require the user to discard this object and
        // instantiate a new one
        
        return State.BROKEN;
    }
    
    //
    // error handling
    //
    
    private uint on_send_error(uint state, uint event, void *user, Object? object, Error? err) {
        assert(err != null);
        debug("Send error on %s: %s", to_full_string(), err.message);
        
        cx = null;
        
        return State.BROKEN;
    }
    
    private uint on_recv_error(uint state, uint event, void *user, Object? object, Error? err) {
        assert(err != null);
        debug("Receive error on %s: %s", to_full_string(), err.message);
        
        cx = null;
        
        return State.BROKEN;
    }
    
    // This handles the situation where the user submits a command before the connection has been
    // established
    private uint on_early_command(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        AsyncParams params = (AsyncParams) object;
        params.err = new ImapError.NOT_CONNECTED("Not connected to %s", to_string());
        
        return state;
    }
    
    // This handles the situation where the user submits a command after the connection has been
    // logged out, terminated, or errored-out
    private uint on_late_command(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        AsyncParams params = (AsyncParams) object;
        params.err = new IOError.CLOSED("Connection to %s closing or closed", to_string());
        
        return state;
    }
    
    private uint on_unauthenticated(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        AsyncParams params = (AsyncParams) object;
        params.err = new ImapError.UNAUTHENTICATED("Not authenticated with %s", to_string());
        
        return state;
    }
    
    private uint on_ignored_transition(uint state, uint event) {
        debug("Ignored transition: %s@%s", fsm.get_event_string(event), fsm.get_state_string(state));
        
        return state;
    }
    
    //
    // command submission
    //
    
    private void issue_status(Status status, Event ok_event, Event error_event, Object? object) {
        fsm.issue((status == Status.OK) ? ok_event : error_event, null, object);
    }
    
    private async AsyncCommandResponse issue_command_async(Command cmd, Object? user = null,
        Cancellable? cancellable = null) {
        if (cx == null) {
            return new AsyncCommandResponse(null, user,
                new IOError.CLOSED("Not connected to %s", server));
        }
        
        try {
            yield cx.send_async(cmd, Priority.DEFAULT, cancellable);
        } catch (Error err) {
            return new AsyncCommandResponse(null, user, err);
        }
        
        cb_queue.offer(new CommandCallback(issue_command_async.callback));
        yield;
        
        CommandResponse? cmd_response = cmd_response_queue.poll();
        assert(cmd_response != null);
        assert(cmd_response.is_sealed());
        assert(cmd_response.status_response.tag.equals(cmd.tag));
        
        return new AsyncCommandResponse(cmd_response, user, null);
    }
    
    private void generic_issue_command_completed(AsyncResult result, Event ok_event, Event error_event) {
        AsyncCommandResponse async_response = issue_command_async.end(result);
        
        assert(async_response.user != null);
        AsyncParams params = (AsyncParams) async_response.user;
        
        params.cmd_response = async_response.cmd_response;
        params.err = async_response.err;
        
        if (async_response.err != null) {
            fsm.issue(Event.SEND_ERROR, null, null, async_response.err);
        } else {
            issue_status(async_response.cmd_response.status_response.status, ok_event, error_event,
                params);
        }
        
        Idle.add(params.cb);
    }
    
    public async CommandResponse send_command_async(Command cmd, Cancellable? cancellable = null) 
        throws Error {
        AsyncCommandResponse async_response = yield issue_command_async(cmd, null, cancellable);
        if (async_response.err != null)
            throw async_response.err;
        
        return async_response.cmd_response;
    }
    
    public async Geary.Folder open(string name, Cancellable? cancellable = null) throws Error {
        if (cx == null)
            throw new IOError.CLOSED("Not connected to %s", server);
        
        assert(current_mailbox == null);
        
        yield send_command_async(new ExamineCommand(cx.generate_tag(), name), cancellable);
        
        current_mailbox = new Mailbox(name, this);
        
        return current_mailbox;
    }
    
    //
    // network connection event handlers
    //
    
    private void on_network_connected() {
        debug("Connected to %s", server);
    }
    
    private void on_network_disconnected() {
        debug("Disconnected from %s", server);
    }
    
    private void on_network_sent_command(Command cmd) {
        debug("Sent command %s", cmd.to_string());
    }
    
    private void on_received_status_response(StatusResponse status_response) {
        assert(!current_cmd_response.is_sealed());
        current_cmd_response.seal(status_response);
        assert(current_cmd_response.is_sealed());
        
        cmd_response_queue.offer(current_cmd_response);
        current_cmd_response = new CommandResponse();
        
        CommandCallback? cmd_callback = cb_queue.poll();
        assert(cmd_callback != null);
        
        Idle.add(cmd_callback.callback);
    }
    
    private void on_received_server_data(ServerData server_data) {
        // The first response from the server is an untagged status response, which is considered
        // ServerData in our model.  This captures that and treats it as such.
        if (awaiting_connect_response) {
            awaiting_connect_response = false;
            connect_response = server_data;
            
            CommandCallback? cmd_callback = cb_queue.poll();
            assert(cmd_callback != null);
            
            Idle.add(cmd_callback.callback);
            
            return;
        }
        
        current_cmd_response.add_server_data(server_data);
    }
    
    private void on_received_bad_response(RootParameters root, ImapError err) {
        debug("Received bad response %s: %s", root.to_string(), err.message);
    }
    
    private void on_receive_failed(Error err) {
        debug("Receive failed: %s", err.message);
        fsm.issue(Event.RECV_ERROR, null, null, err);
    }
    
    public string to_string() {
        return "ClientSession:%s:%u".printf(server, default_port);
    }
    
    public string to_full_string() {
        return "%s [%s]".printf(to_string(), fsm.get_state_string(fsm.get_state()));
    }
}
