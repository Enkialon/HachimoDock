//! Desktop IPC adapter; the account service itself is tested without Tauri.
#[tauri::command]
pub async fn codex_accounts_request(input: serde_json::Value) -> Result<serde_json::Value, String> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = input;
        return Err("当前系统尚未启用 Codex 额度账号管理".into());
    }
    #[cfg(target_os = "macos")]
    tauri::async_runtime::spawn_blocking(move || {
        crate::local_telemetry::accounts::manager::request(input)
    })
    .await
    .map_err(|_| "账号管理任务未完成，请刷新检查".to_string())?
}
