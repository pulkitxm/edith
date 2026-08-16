use std::io;
use std::path::{Path, PathBuf};

use tokio::fs::{self, OpenOptions};
use tokio::io::AsyncWriteExt;

pub async fn write_vault_file(
    vault_dir: &Path,
    sha256: &str,
    name: &str,
    bytes: &[u8],
) -> io::Result<String> {
    let basename = Path::new(name)
        .file_name()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "file name has no basename"))?;
    if sha256.len() < 2 || !sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "the sha256 is not a hex digest",
        ));
    }
    let relative = PathBuf::from("objects")
        .join(&sha256[..2])
        .join(sha256)
        .join(basename);
    let path = vault_dir.join(&relative);

    if fs::try_exists(&path).await? {
        return Ok(relative.to_string_lossy().into_owned());
    }

    let directory = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "vault path has no parent"))?;
    fs::create_dir_all(directory).await?;

    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .await
    {
        Ok(mut file) => file.write_all(bytes).await?,
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }

    Ok(relative.to_string_lossy().into_owned())
}
