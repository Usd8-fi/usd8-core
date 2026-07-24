#![cfg(feature = "sepolia")]

use usd8_tee_job_api::settlement_rpc_url;

#[test]
fn sepolia_feature_pins_rpc_network() {
    assert_eq!(
        settlement_rpc_url(),
        "https://lb.drpc.live/ogrpc?network=sepolia"
    );
}

#[test]
fn sepolia_proxy_allows_only_the_baked_rpc_host() {
    use usd8_tee_job_api::connect_proxy_port;

    assert_eq!(
        connect_proxy_port(b"CONNECT lb.drpc.live:443 HTTP/1.1\r\n\r\n"),
        Some(9002)
    );
    assert_eq!(
        connect_proxy_port(b"CONNECT lb.drpc.org:443 HTTP/1.1\r\n\r\n"),
        None
    );
}
