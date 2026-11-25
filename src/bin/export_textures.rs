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
        for intensity in 15..=30 {
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

#[cfg(test)]
#[test]
fn warm_tones_are_distinct_and_preserve_alpha_at_every_texture_and_intensity() {
    use sue_paper::tone::Tone;

    for kind in KINDS {
        for intensity in 15..=30 {
            let original = generate_tile(kind, intensity);
            let mut previous = i64::MIN;
            for tone in Tone::ALL {
                let mut tile = original.clone();
                tone.apply(&mut tile);
                let mut red_minus_blue = 0;
                for ([b, g, r, a], base) in tile
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .zip(original.as_chunks::<4>().0)
                {
                    assert_eq!(*a, base[3]);
                    assert!(b <= a && g <= a && r <= a);
                    red_minus_blue += i64::from(*r) - i64::from(*b);
                }
                assert!(red_minus_blue > previous);
                previous = red_minus_blue;
                if tone == Tone::Original {
                    assert_eq!(tile, original);
                }
            }
        }
    }
}
