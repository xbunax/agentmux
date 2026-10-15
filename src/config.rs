//! First-launch configuration using the launch directory and installed executables.

use crate::{Agents, Config};
use std::{
    ffi::OsStr,
    fs::{self, OpenOptions},
    io::{ErrorKind, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::Path,
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

pub fn load_or_create(path: &Path) -> Result<Config> {
    match fs::read(path) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes)?),
        Err(error) if error.kind() == ErrorKind::NotFound => create(
            path,
            &std::env::current_dir()?,
            std::env::var_os("PATH").as_deref(),
        ),
        Err(error) => Err(error.into()),
    }
}

fn executable(name: &str, directory: &Path, search_path: Option<&OsStr>) -> String {
    if let Some(search_path) = search_path {
        for entry in std::env::split_paths(search_path) {
            let candidate = directory.join(entry).join(name);
            if fs::metadata(&candidate).is_ok_and(|metadata| {
                metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
            }) {
                return candidate.to_string_lossy().into_owned();
            }
        }
    }
    name.into()
}

fn create(path: &Path, directory: &Path, search_path: Option<&OsStr>) -> Result<Config> {
    let directory = directory.canonicalize()?;
    let config = Config {
        revision: 0,
        roots: vec![directory.clone()],
        default_directory: directory.clone(),
        agents: Agents {
            codex: executable("codex", &directory, search_path),
            claude: executable("claude", &directory, search_path),
            pi: executable("pi", &directory, search_path),
        },
    };
    let mut bytes = serde_json::to_vec_pretty(&config)?;
    bytes.push(b'\n');
    // Never truncate an existing config, including one created by another process.
    let mut file = match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            return Ok(serde_json::from_slice(&fs::read(path)?)?);
        }
        Err(error) => return Err(error.into()),
    };
    file.write_all(&bytes)?;
    file.sync_all()?;
    eprintln!(
        "Created {}: authorized project directory {}",
        path.display(),
        directory.display()
    );
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_launch_creates_private_config_for_only_the_launch_directory() {
        let root = tempfile::tempdir().unwrap();
        let project = root.path().join("project");
        fs::create_dir(&project).unwrap();
        let path = project.join("agentmux.json");
        let config = create(&path, &project, None).unwrap();
        assert_eq!(config.roots, vec![project.canonicalize().unwrap()]);
        assert_eq!(config.default_directory, config.roots[0]);
        assert_eq!(config.revision, 0);
        assert_eq!(config.agents.codex, "codex");
        assert_eq!(config.agents.claude, "claude");
        assert_eq!(config.agents.pi, "pi");
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let loaded = load_or_create(&path).unwrap();
        assert_eq!(loaded.roots, config.roots);
    }

    #[test]
    fn executable_detection_skips_non_executables_and_preserves_symlinks() {
        let root = tempfile::tempdir().unwrap();
        let bin = root.path().join("bin with spaces");
        fs::create_dir(&bin).unwrap();
        fs::write(root.path().join("codex"), "not executable").unwrap();
        let target = bin.join("agent-entrypoint");
        fs::write(&target, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o700)).unwrap();
        let link = bin.join("codex");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let search_path =
            std::env::join_paths([Path::new(""), Path::new("bin with spaces")]).unwrap();
        assert_eq!(
            executable("codex", root.path(), Some(&search_path)),
            link.to_string_lossy()
        );
        fs::create_dir(bin.join("claude")).unwrap();
        assert_eq!(
            executable("claude", root.path(), Some(&search_path)),
            "claude"
        );
    }

    #[test]
    fn existing_configuration_is_preserved_even_when_creation_is_attempted() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("custom.json");
        create(&path, root.path(), None).unwrap();
        let mut config = load_or_create(&path).unwrap();
        config.revision = 9;
        config.agents.codex = "/custom/codex".into();
        let bytes = serde_json::to_vec_pretty(&config).unwrap();
        fs::write(&path, &bytes).unwrap();
        let loaded = create(&path, root.path(), None).unwrap();
        assert_eq!(loaded.revision, 9);
        assert_eq!(loaded.agents.codex, "/custom/codex");
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }

    #[test]
    fn invalid_existing_configuration_is_reported_without_overwriting() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("agentmux.json");
        let bytes = b"invalid configuration";
        fs::write(&path, bytes).unwrap();
        assert!(load_or_create(&path).is_err());
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }
}
