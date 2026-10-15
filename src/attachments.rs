//! Private, bounded uploads. Clients supply receipt IDs, never arbitrary native image paths.
use crate::*;
use axum::body::Bytes;
use axum::response::{IntoResponse, Response};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use tokio::io::{AsyncReadExt, BufReader};

pub const MARKER: &str = "\n\n附件（AgentMux，已上传至 Mac）：\n";
pub struct Store {
    root: PathBuf,
    writes: Mutex<()>,
}
impl Store {
    pub fn temporary(state: &FsPath) -> std::io::Result<Self> {
        let state = state.canonicalize()?;
        let owner = state.metadata()?.uid();
        let namespace = format!("{:x}", Sha256::digest(state.as_os_str().as_encoded_bytes()));
        let root =
            PathBuf::from("/tmp").join(format!("agentmux-uploads-{owner}-{}", &namespace[..12]));
        match std::fs::DirBuilder::new().mode(0o700).create(&root) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                let metadata = std::fs::symlink_metadata(&root)?;
                if !metadata.is_dir()
                    || metadata.uid() != owner
                    || metadata.permissions().mode() & 0o077 != 0
                {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::PermissionDenied,
                        "Attachment temporary directory must be private and owned by the service user",
                    ));
                }
            }
            Err(error) => return Err(error),
        }
        Ok(Self::new(root))
    }
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            writes: Mutex::new(()),
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Attachment {
    pub id: String,
    pub name: String,
    pub size: usize,
    pub mime_type: String,
    pub path: PathBuf,
}
#[derive(Serialize, Deserialize)]
struct Receipt {
    file: Attachment,
    digest: String,
}
#[derive(Deserialize)]
pub struct Upload {
    name: String,
}
fn valid_id(id: &str) -> bool {
    uuid::Uuid::parse_str(id).is_ok_and(|value| value.to_string() == id)
}
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 240
        && name != "."
        && name != ".."
        && !name
            .chars()
            .any(|c| c.is_control() || ['/', '\\'].contains(&c))
}
fn mime(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        "image/png"
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        "image/jpeg"
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        "image/gif"
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        "image/webp"
    } else if bytes.starts_with(b"%PDF-") {
        "application/pdf"
    } else {
        "application/octet-stream"
    }
}
async fn read(app: &App, id: &str) -> Result<Receipt> {
    if !valid_id(id) {
        return Err(bad("Invalid attachment ID"));
    }
    let file = tokio::fs::File::open(app.attachments.root.join(id).join("receipt.json"))
        .await
        .map_err(|_| (StatusCode::NOT_FOUND, "附件不存在，请重新选择文件。".into()))?;
    let mut data = Vec::new();
    BufReader::new(file)
        .take(65537)
        .read_to_end(&mut data)
        .await
        .map_err(internal)?;
    if data.len() > 65536 {
        return Err(bad("Invalid attachment receipt"));
    }
    let receipt: Receipt = serde_json::from_slice(&data).map_err(internal)?;
    let expected = app
        .attachments
        .root
        .join(id)
        .join("content")
        .join(&receipt.file.name);
    if !valid_name(&receipt.file.name) || receipt.file.id != id || receipt.file.path != expected {
        return Err(bad("Invalid attachment receipt"));
    }
    let actual = tokio::fs::canonicalize(&expected).await.map_err(internal)?;
    let root = tokio::fs::canonicalize(&app.attachments.root)
        .await
        .map_err(internal)?;
    let metadata = tokio::fs::symlink_metadata(&expected)
        .await
        .map_err(internal)?;
    if !actual.starts_with(root.join(id).join("content"))
        || !metadata.is_file()
        || metadata.len() != receipt.file.size as u64
        || metadata.len() > MAX_FILE as u64
    {
        return Err(bad("Attachment file changed"));
    }
    Ok(receipt)
}
pub async fn upload(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(query): Query<Upload>,
    bytes: Bytes,
) -> Result<Json<Attachment>> {
    authorize(&headers, &app)?;
    if !valid_id(&id) || !valid_name(&query.name) {
        return Err(bad("Invalid attachment name or ID"));
    }
    if bytes.len() > MAX_FILE {
        return Err((StatusCode::PAYLOAD_TOO_LARGE, "附件不能超过 8 MiB。".into()));
    }
    let _write = app.attachments.writes.lock().await;
    let digest = format!("{:x}", Sha256::digest(&bytes));
    let directory = app.attachments.root.join(&id);
    if tokio::fs::try_exists(&directory).await.map_err(internal)? {
        let old = read(&app, &id).await?;
        if old.digest != digest || old.file.name != query.name {
            return Err((
                StatusCode::CONFLICT,
                "Attachment ID already contains a different file".into(),
            ));
        }
        verified_bytes(&old).await?;
        return Ok(Json(old.file));
    }
    tokio::fs::create_dir_all(&app.attachments.root)
        .await
        .map_err(internal)?;
    tokio::fs::set_permissions(
        &app.attachments.root,
        std::fs::Permissions::from_mode(0o700),
    )
    .await
    .map_err(internal)?;
    let mut entries = tokio::fs::read_dir(&app.attachments.root)
        .await
        .map_err(internal)?;
    let mut total = 0usize;
    let mut count = 0;
    while let Some(entry) = entries.next_entry().await.map_err(internal)? {
        count += 1;
        if let Ok(old) = read(&app, &entry.file_name().to_string_lossy()).await {
            total += old.file.size;
        }
        if count >= 512 || total + bytes.len() > 256 * 1024 * 1024 {
            return Err((
                StatusCode::INSUFFICIENT_STORAGE,
                "Mac 的附件存储已满，请清理后再上传。".into(),
            ));
        }
    }
    tokio::fs::create_dir(&directory).await.map_err(internal)?;
    tokio::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
        .await
        .map_err(internal)?;
    let content = directory.join("content");
    tokio::fs::create_dir(&content).await.map_err(internal)?;
    let path = content.join(query.name.clone());
    let file = Attachment {
        id,
        name: query.name,
        size: bytes.len(),
        mime_type: mime(&bytes).into(),
        path,
    };
    let receipt = Receipt {
        file: file.clone(),
        digest,
    };
    let result = async {
        tokio::fs::write(&file.path, &bytes)
            .await
            .map_err(internal)?;
        tokio::fs::set_permissions(&file.path, std::fs::Permissions::from_mode(0o600))
            .await
            .map_err(internal)?;
        tokio::fs::write(
            directory.join("receipt.json"),
            serde_json::to_vec(&receipt).map_err(internal)?,
        )
        .await
        .map_err(internal)?;
        tokio::fs::set_permissions(
            directory.join("receipt.json"),
            std::fs::Permissions::from_mode(0o600),
        )
        .await
        .map_err(internal)?;
        Ok::<_, Error>(())
    }
    .await;
    if result.is_err() {
        let _ = tokio::fs::remove_dir_all(&directory).await;
    }
    result?;
    Ok(Json(file))
}
pub async fn download(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Response> {
    authorize(&headers, &app)?;
    let receipt = read(&app, &id).await?;
    let bytes = verified_bytes(&receipt).await?;
    Ok((
        [
            ("content-type", receipt.file.mime_type.as_str()),
            ("x-content-type-options", "nosniff"),
        ],
        bytes,
    )
        .into_response())
}
pub async fn prepare(app: &App, text: &str, ids: &[String]) -> Result<(String, Vec<Attachment>)> {
    if ids.is_empty() {
        return Ok((text.into(), vec![]));
    }
    if ids.len() > 6 || text.trim_start().starts_with('/') {
        return Err(bad("每条消息最多 6 个附件；slash 命令请单独发送。"));
    }
    let mut files = Vec::new();
    let mut total = 0;
    for id in ids {
        if files.iter().any(|file: &Attachment| &file.id == id) {
            return Err(bad("Duplicate attachment"));
        }
        let receipt = read(app, id).await?;
        verified_bytes(&receipt).await?;
        let file = receipt.file;
        total += file.size;
        if total > 24 * 1024 * 1024 {
            return Err(bad("每条消息的附件总量不能超过 24 MiB。"));
        }
        files.push(file);
    }
    let caption = if text.trim().is_empty() {
        "请查看这些附件。"
    } else {
        text
    };
    let text = format!("{caption}{MARKER}{}", json!({"attachments": files}));
    Ok((text, files))
}
pub fn files_json(files: &[Attachment]) -> Value {
    json!(files)
}
async fn verified_bytes(receipt: &Receipt) -> Result<Vec<u8>> {
    let bytes = bounded_bytes(&receipt.file.path).await?;
    if bytes.len() != receipt.file.size || format!("{:x}", Sha256::digest(&bytes)) != receipt.digest
    {
        return Err((StatusCode::CONFLICT, "附件内容已变化，请重新上传。".into()));
    }
    Ok(bytes)
}
async fn bounded_bytes(path: &FsPath) -> Result<Vec<u8>> {
    let file = tokio::fs::File::open(path).await.map_err(internal)?;
    let mut bytes = Vec::new();
    BufReader::new(file)
        .take((MAX_FILE + 1) as u64)
        .read_to_end(&mut bytes)
        .await
        .map_err(internal)?;
    if bytes.len() > MAX_FILE {
        return Err(bad("Attachment file changed"));
    }
    Ok(bytes)
}
pub async fn images(files: &[Attachment]) -> Result<Vec<Value>> {
    use base64::Engine;
    let mut images = Vec::new();
    for file in files
        .iter()
        .filter(|file| file.mime_type.starts_with("image/"))
    {
        let bytes = bounded_bytes(&file.path).await?;
        images.push(json!({"type":"image","data":base64::engine::general_purpose::STANDARD.encode(bytes),"mimeType":file.mime_type}));
    }
    Ok(images)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn names_ids_and_image_types_are_bounded_and_not_path_or_mime_claims() {
        assert!(valid_name("设计图 1.png"));
        for name in ["", "../secret", "a/b", "a\\b", "..", "a\nfile"] {
            assert!(!valid_name(name));
        }
        assert!(!valid_id("../secret"));
        assert!(valid_id("12345678-1234-4234-8234-123456789abc"));
        assert_eq!(mime(b"\x89PNG\r\n\x1a\nrest"), "image/png");
        assert_eq!(
            mime(b"plain text named photo.png"),
            "application/octet-stream"
        );
    }
}
