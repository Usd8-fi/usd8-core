#[test]
fn production_lambda_installs_independent_completion_verification() {
    let library = include_str!("../src/lib.rs");
    let lambda = include_str!("../src/bin/lambda.rs");
    assert!(library.contains("pub mod settlement_verifier;"));
    assert!(library.contains("pub mod completion_verifier;"));
    assert!(lambda.contains("RpcCompletionVerifier::new("));
    assert!(lambda.contains(".with_completion_verifier("));
}
