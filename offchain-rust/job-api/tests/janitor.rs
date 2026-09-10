use usd8_tee_job_api::is_expired;

#[test]
fn janitor_terminates_only_instances_strictly_older_than_ttl() {
    assert!(!is_expired(100, 399, 300));
    assert!(!is_expired(100, 400, 300));
    assert!(is_expired(100, 401, 300));
    assert!(!is_expired(500, 400, 300));
}
