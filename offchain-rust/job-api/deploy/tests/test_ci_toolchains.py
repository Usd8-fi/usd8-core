import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[4]
WORKFLOW = ROOT / ".github" / "workflows" / "test.yml"


class CiToolchainTest(unittest.TestCase):
    def test_job_api_uses_declared_rust_toolchain(self) -> None:
        workflow = WORKFLOW.read_text()
        self.assertIn("rustup toolchain install 1.94.1", workflow)
        self.assertIn(
            'USD8_REGISTRY: "0x0000000000000000000000000000000000000001"',
            workflow,
        )

        job_api_section = workflow.split("- name: Check TEE job API formatting", 1)[1]
        job_api_section = job_api_section.split("- name: Test standalone real-history helpers", 1)[0]
        cargo_commands = [
            line.strip()
            for line in job_api_section.splitlines()
            if line.strip().startswith("cargo ")
        ]
        self.assertTrue(cargo_commands)
        self.assertTrue(
            all(command.startswith("cargo +1.94.1 ") for command in cargo_commands),
            cargo_commands,
        )


if __name__ == "__main__":
    unittest.main()
