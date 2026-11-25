use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum Tone {
    #[default]
    Original = 0,
    LightWarm = 1,
    WarmPaper = 2,
}

impl Tone {
    pub const ALL: [Self; 3] = [Self::Original, Self::LightWarm, Self::WarmPaper];

    pub fn apply(self, bgra: &mut [u8]) {
        let (red, green, blue) = match self {
            Self::Original => return,
            Self::LightWarm => (14, 3, 18),
            Self::WarmPaper => (30, 6, 38),
        };
        for [b, g, r, a] in bgra.as_chunks_mut::<4>().0 {
            // Apply the color offsets in premultiplied space and keep the original alpha.
            let shift = |amount: u16| ((amount * u16::from(*a) + 127) / 255) as u8;
            *b = b.saturating_sub(shift(blue));
            *g = g.saturating_add(shift(green)).min(*a);
            *r = r.saturating_add(shift(red)).min(*a);
        }
    }
}

/// Apply a tone to the exported BGRA pixels owned by the macOS caller.
///
/// # Safety
/// `pixels` must be writable for `len` bytes and exclusively borrowed for this call.
#[no_mangle]
pub unsafe extern "C" fn matte_apply_tone(pixels: *mut u8, len: usize, tone: u8) {
    if let Some(tone) = Tone::ALL.get(usize::from(tone)) {
        tone.apply(unsafe { std::slice::from_raw_parts_mut(pixels, len) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tone_adjusts_premultiplied_color_and_preserves_alpha() {
        let original = [30, 32, 34, 64, 0, 64, 64, 64, 0, 0, 0, 0];
        for (tone, first) in [
            (Tone::Original, [30, 32, 34, 64]),
            (Tone::LightWarm, [25, 33, 38, 64]),
            (Tone::WarmPaper, [20, 34, 42, 64]),
        ] {
            let mut data = original;
            tone.apply(&mut data);
            assert_eq!(data[..4], first);
            assert_eq!(data[4..], original[4..]);

            let mut bridged = original;
            unsafe { matte_apply_tone(bridged.as_mut_ptr(), bridged.len(), tone as u8) };
            assert_eq!(bridged, data);
        }
    }
}
