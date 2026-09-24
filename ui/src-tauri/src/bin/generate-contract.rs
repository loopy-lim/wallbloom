fn main() -> rustra::Result<()> {
    let output = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../src/generated");
    wallbloom_ui::bridge::package().generate_typescript()?.write_schema_to_dir(output)?;
    Ok(())
}
