use usd8_tee_job_api::{connect_proxy_port, settlement_rpc_authority};

#[test]
fn connect_proxy_allows_only_fixed_tls_destinations() {
    assert_eq!(
        connect_proxy_port(b"CONNECT kms.eu-central-1.amazonaws.com:443 HTTP/1.1\r\nHost: kms.eu-central-1.amazonaws.com:443\r\n\r\n"),
        Some(9001)
    );
    let rpc_request = format!(
        "CONNECT {} HTTP/1.1\r\nHost: {}\r\n\r\n",
        settlement_rpc_authority(),
        settlement_rpc_authority()
    );
    assert_eq!(connect_proxy_port(rpc_request.as_bytes()), Some(9002));
    for request in [
        b"CONNECT evil.example:443 HTTP/1.1\r\n\r\n".as_slice(),
        b"GET https://lb.drpc.org/ HTTP/1.1\r\n\r\n".as_slice(),
        b"CONNECT lb.drpc.org:80 HTTP/1.1\r\n\r\n".as_slice(),
        b"CONNECT lb.drpc.org:443 HTTP/2\r\n\r\n".as_slice(),
        b"CONNECT lb.drpc.org:443 HTTP/1.1\r\n".as_slice(),
    ] {
        assert_eq!(connect_proxy_port(request), None);
    }
}
