use rustra::prelude::*;
use crate::WallPackage;

// Tauri's JSON adapter sends an object even for a no-argument command.
#[bridge_type]
pub struct ScanLibraryInput {}

#[command]
fn scan_library(_input: ScanLibraryInput) -> rustra::Result<Vec<WallPackage>> {
    crate::scan_library().map_err(rustra::RustraError::internal)
}

#[bridge_type]
#[derive(Clone)]
pub struct DownloadProgress {
    pub received_bytes: u64,
    pub total_bytes: Option<u64>,
}

pub fn package() -> rustra::Package {
    rustra::build!("wallbloom.library", scan_library)
        .event::<DownloadProgress>("download-progress")
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn progress_preserves_the_existing_wire_contract() {
        let progress = DownloadProgress { received_bytes: 1024, total_bytes: None };
        assert_eq!(serde_json::to_value(progress).unwrap(),
            serde_json::json!({"receivedBytes": 1024, "totalBytes": null}));
    }

    #[test]
    fn registered_scan_dispatch_preserves_the_existing_result() {
        let expected = crate::scan_library().unwrap();
        let actual = package().invoke_json("scanLibrary", serde_json::json!({})).unwrap();
        assert_eq!(actual, serde_json::to_value(expected).unwrap());
    }

    #[test]
    fn registered_contract_rejects_unknown_commands() {
        let error = package().invoke_json("not_a_command", serde_json::json!({})).unwrap_err();
        assert_eq!(error.code(), "command.not_found");
    }
}
