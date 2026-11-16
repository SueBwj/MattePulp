//! Export the shared texture engine's premultiplied BGRA tiles for the macOS bundle.

#[path = "../texture.rs"]
mod texture;

use std::{io, path::PathBuf};
use texture::{generate_tile, KINDS, KIND_NAMES};

fn main() -> io::Result<()> {
    let directory = std::env::args_os().nth(1).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: export_textures DIRECTORY",
        )
    })?;
    let directory = PathBuf::from(directory);
    std::fs::create_dir_all(&directory)?;
    let mut catalog = Vec::new();
    for (kind, name) in KINDS.iter().zip(KIND_NAMES) {
        let id = serde_json::to_value(kind).map_err(io::Error::other)?;
        let id = id.as_str().expect("texture kinds serialize as strings");
        for intensity in [15, 20, 25, 30] {
            std::fs::write(
                directory.join(format!("{id}-{intensity}.bgra")),
                generate_tile(*kind, intensity),
            )?;
        }
        catalog.push(serde_json::json!({ "id": id, "name": name }));
    }
    std::fs::write(
        directory.join("catalog.json"),
        serde_json::to_vec_pretty(&catalog).map_err(io::Error::other)?,
    )
}
