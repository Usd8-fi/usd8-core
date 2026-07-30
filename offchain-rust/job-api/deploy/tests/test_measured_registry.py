import pathlib
import unittest


JOB_API = pathlib.Path(__file__).resolve().parents[2]
ENCLAVE = JOB_API / "src" / "bin" / "enclave.rs"
BUILD_RELEASE = JOB_API / "deploy" / "build-release.sh"
FINALIZE_RELEASE = JOB_API / "deploy" / "finalize-release.sh"


class MeasuredRegistryTest(unittest.TestCase):
    def test_enclave_has_no_registry_fallback(self) -> None:
        source = ENCLAVE.read_text()
        self.assertRegex(source, r'env!\(\s*"USD8_REGISTRY"')
        self.assertNotIn('option_env!("USD8_REGISTRY")', source)
        self.assertNotIn("0x3Fa82eC1842f72c36580D84E03377b10B5E2F590", source)

    def test_release_build_supplies_registry_to_enclave_compilation(self) -> None:
        script = BUILD_RELEASE.read_text()
        self.assertIn('USD8_REGISTRY="$REGISTRY"', script)
        self.assertIn("--bin usd8-tee-enclave", script)

    def test_release_build_is_sepolia_only(self) -> None:
        script = BUILD_RELEASE.read_text()
        self.assertIn('NETWORK=${NETWORK:?set NETWORK to sepolia}', script)
        self.assertIn('[[ "$NETWORK" == sepolia ]]', script)
        self.assertNotIn('NETWORK must be ethereum or sepolia', script)

    def test_release_build_discards_unmanifested_measurements_sidecar(self) -> None:
        script = BUILD_RELEASE.read_text()
        self.assertIn('rm -f "$RELEASE/measurements.json"', script)

    def test_finalization_binds_pcr3_and_kms_principal_to_selected_role(self) -> None:
        source = FINALIZE_RELEASE.read_text()
        self.assertIn('aws iam get-role --role-name "$INSTANCE_ROLE"', source)
        self.assertIn('--pcr3-for-role-arn "$INSTANCE_ROLE_ARN"', source)
        self.assertIn('.Principal.AWS = $roleArn', source)
        self.assertGreaterEqual(
            source.count('["kms:RecipientAttestation:PCR3"] = $pcr3'),
            2,
        )

    def test_finalization_labels_output_as_a_candidate_pending_live_verification(self) -> None:
        source = FINALIZE_RELEASE.read_text()
        self.assertIn('RELEASE_CANDIDATE_CREATED=', source)
        self.assertIn('verify-release.py "%s/release-manifest.json" --live --rpc-url', source)


if __name__ == "__main__":
    unittest.main()
