//for testing and debugging, this command allows direct access to the underlying FFI functions for root, digest, claimset, and proof generation.
const USAGE: &str = "usage:\n  usd8-ffi <root|proof|digest|claimset> <abiHexPayload> [claimId]";

fn usage(message: &str) -> ! {
    eprintln!("ERROR: {message}");
    eprintln!("{USAGE}");
    std::process::exit(2);
}

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.len() == 1 && matches!(args[0].as_str(), "--help" | "-h" | "help") {
        println!("{USAGE}");
        return;
    }
    let command = args.first().unwrap_or_else(|| usage("missing FFI command"));
    let expected = match command.as_str() {
        "root" | "digest" | "claimset" => 2,
        "proof" => 3,
        value => usage(&format!("unknown FFI command: {value}")),
    };
    if args.len() != expected {
        usage(&format!(
            "FFI {command} expects {} argument(s) after the command",
            expected - 1
        ));
    }
    match usd8_settlement::ffi::run(&args[0], &args[1], args.get(2).map(String::as_str)) {
        Ok(output) => print!("{output}"),
        Err(error) => {
            eprintln!("FATAL: {error}");
            std::process::exit(1);
        }
    }
}
