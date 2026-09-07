use serde_json::json;
use usd8_tee_job_api::{TerminalEnvelope, TerminalStatus};

#[test]
fn terminal_envelope_is_single_versioned_discriminated_object() {
    let completed = TerminalEnvelope::completed(&"a".repeat(64), json!({"signature":"0x01"}));
    assert_eq!(completed.status, TerminalStatus::Completed);
    assert_eq!(
        serde_json::to_value(&completed).unwrap()["status"],
        "completed"
    );

    let failed = TerminalEnvelope::failed(&"a".repeat(64), "ENCLAVE_FAILED");
    let value = serde_json::to_value(failed).unwrap();
    assert_eq!(value["status"], "failed");
    assert_eq!(value["payload"]["code"], "ENCLAVE_FAILED");
    assert!(value["payload"].get("message").is_none());
}
