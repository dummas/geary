/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

/**
 * An Endpoint represents the location of an Internet TCP connection as represented by a host,
 * a port, and flags and other parameters that specify the nature of the connection itself.
 */

public class Geary.Endpoint : Object {
    [Flags]
    public enum Flags {
        NONE = 0,
        SSL,
        STARTTLS,
        GRACEFUL_DISCONNECT;
        
        public inline bool is_all_set(Flags flags) {
            return (this & flags) == flags;
        }
        
        public inline bool is_any_set(Flags flags) {
            return (this & flags) != 0;
        }
    }
    
    public enum AttemptStarttls {
        YES,
        NO,
        HALT
    }
    
    public string host_specifier { get; private set; }
    public uint16 default_port { get; private set; }
    public Flags flags { get; private set; }
    public uint timeout_sec { get; private set; }
    public TlsCertificateFlags tls_validation_flags { get; set; default = TlsCertificateFlags.VALIDATE_ALL; }
    public bool force_ssl3 { get; set; default = false; }
    
    public bool is_ssl { get {
        return flags.is_all_set(Flags.SSL);
    } }
    
    public bool use_starttls { get {
        return flags.is_all_set(Flags.STARTTLS);
    } }
    
    private SocketClient? socket_client = null;
    
    public Endpoint(string host_specifier, uint16 default_port, Flags flags, uint timeout_sec) {
        this.host_specifier = host_specifier;
        this.default_port = default_port;
        this.flags = flags;
        this.timeout_sec = timeout_sec;
    }
    
    public SocketClient get_socket_client() {
        if (socket_client != null)
            return socket_client;

        socket_client = new SocketClient();

        if (is_ssl) {
            socket_client.set_tls(true);
            socket_client.set_tls_validation_flags(tls_validation_flags);
            socket_client.event.connect(on_socket_client_event);
        }

        socket_client.set_timeout(timeout_sec);

        return socket_client;
    }

    public async SocketConnection connect_async(Cancellable? cancellable = null) throws Error {
        SocketConnection cx = yield get_socket_client().connect_to_host_async(host_specifier, default_port,
            cancellable);

        TcpConnection? tcp = cx as TcpConnection;
        if (tcp != null)
            tcp.set_graceful_disconnect(flags.is_all_set(Flags.GRACEFUL_DISCONNECT));

        return cx;
    }
    
    public async TlsClientConnection starttls_handshake_async(IOStream base_stream,
        SocketConnectable connectable, Cancellable? cancellable = null) throws Error {
        TlsClientConnection tls_cx = TlsClientConnection.new(base_stream, connectable);
        prepare_tls_cx(tls_cx, true);
        
        yield tls_cx.handshake_async(Priority.DEFAULT, cancellable);
        
        return tls_cx;
    }
    
    private void on_socket_client_event(SocketClientEvent event, SocketConnectable? connectable,
        IOStream? ios) {
        // get TlsClientConnection to bind signals and set flags prior to handshake
        if (event == SocketClientEvent.TLS_HANDSHAKING)
            prepare_tls_cx((TlsClientConnection) ios, false);
    }
    
    private void prepare_tls_cx(TlsClientConnection tls_cx, bool starttls) {
        tls_cx.use_ssl3 = force_ssl3;
        tls_cx.set_validation_flags(tls_validation_flags);
        
        // Vala doesn't do delegates in a ternary operator very well
        if (starttls)
            tls_cx.accept_certificate.connect(on_accept_starttls_certificate);
        else
            tls_cx.accept_certificate.connect(on_accept_ssl_certificate);
    }
    
    private bool on_accept_starttls_certificate(TlsConnection cx, TlsCertificate cert, TlsCertificateFlags flags) {
        return report_tls_warnings("STARTTLS", flags);
    }
    
    private bool on_accept_ssl_certificate(TlsConnection cx, TlsCertificate cert, TlsCertificateFlags flags) {
        return report_tls_warnings("SSL", flags);
    }
    
    private bool report_tls_warnings(string cx_type, TlsCertificateFlags warnings) {
        // TODO: Report or verify flags with user, but for now merely log for informational/debugging
        // reasons and accede
        message("%s TLS warnings connecting to %s: %Xh (%s)", cx_type, to_string(), warnings,
            tls_flags_to_string(warnings));
        
        return true;
    }
    
    private string tls_flags_to_string(TlsCertificateFlags flags) {
        StringBuilder builder = new StringBuilder();
        for (int pos = 0; pos < sizeof (TlsCertificateFlags) * 8; pos++) {
            TlsCertificateFlags flag = flags & (1 << pos);
            if (flag != 0) {
                if (!String.is_empty(builder.str))
                    builder.append(" | ");
                
                builder.append(tls_flag_to_string(flag));
            }
        }
        
        return !String.is_empty(builder.str) ? builder.str : "(none)";
    }
    
    // Vala to_string() for Flags enums currently doesn't work -- bummer...
    // Should only be called when a single flag is set, otherwise returns a string indicating an
    // unknown value
    public string tls_flag_to_string(TlsCertificateFlags flag) {
        switch (flag) {
            case TlsCertificateFlags.BAD_IDENTITY:
                return "BAD_IDENTITY";
            
            case TlsCertificateFlags.EXPIRED:
                return "EXPIRED";
            
            case TlsCertificateFlags.GENERIC_ERROR:
                return "GENERIC_ERROR";
            
            case TlsCertificateFlags.INSECURE:
                return "INSECURE";
            
            case TlsCertificateFlags.NOT_ACTIVATED:
                return "NOT_ACTIVATED";
            
            case TlsCertificateFlags.REVOKED:
                return "REVOKED";
            
            case TlsCertificateFlags.UNKNOWN_CA:
                return "UNKNOWN_CA";
            
            default:
                return "(unknown=%Xh)".printf(flag);
        }
    }
    
    /**
     * Returns true if a STARTTLS command should be attempted on the connection:
     * (a) STARTTLS is reported available (a parameter specified by the caller to this method),
     * (b) not using SSL (so TLS is not required), and (c) STARTTLS is specified as a flag on
     * the Endpoint.
     *
     * If AttemptStarttls.HALT is returned, the caller should not proceed to pass any
     * authentication information down the connection; this situation indicates the connection is
     * insecure and the Endpoint is configured otherwise.
     */
    public AttemptStarttls attempt_starttls(bool starttls_available) {
        if (is_ssl || !use_starttls)
            return AttemptStarttls.NO;
        
        if (!starttls_available)
            return AttemptStarttls.HALT;
        
        return AttemptStarttls.YES;
    }
    
    public string to_string() {
        return "%s/default:%u".printf(host_specifier, default_port);
    }
}

