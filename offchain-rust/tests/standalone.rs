use std::fs;
use std::path::{Path, PathBuf};

fn files_under(root: &Path, out: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(root).expect("read package directory") {
        let path = entry.expect("read package entry").path();
        if path.file_name().is_some_and(|name| name == "target") {
            continue;
        }
        if path.is_dir() {
            files_under(&path, out);
        } else {
            out.push(path);
        }
    }
}

#[test]
fn rust_package_is_standalone() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut files = Vec::new();
    files_under(root, &mut files);

    let script_extension = ["m", "j", "s"].concat();
    assert!(
        files.iter().all(
            |path| path.extension().and_then(|value| value.to_str()) != Some(&script_extension)
        ),
        "the Rust package must not contain JavaScript runtime or comparison scripts"
    );

    let manifest = fs::read_to_string(root.join("Cargo.toml")).expect("read Cargo.toml");
    let legacy_runtime = ["../off", "chain"].concat();
    assert!(
        !manifest.contains(&legacy_runtime),
        "Cargo.toml must not depend on the legacy runtime tree"
    );
}
