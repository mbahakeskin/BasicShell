//! A tab's icon: the page's favicon from WebKit's favicon database, made
//! small (32 pixels at most, what the sidebar shows at 16) and kept as
//! straight-alpha RGBA, as a canvas takes it.

use wpe_webkit::prelude::*;

/// The size icons are kept at, at most.
const SIZE: i32 = 32;

#[derive(Clone)]
pub struct Icon {
    pub width: i32,
    pub height: i32,
    /// RGBA, 8 bits each, not premultiplied, rows without padding.
    pub rgba: Vec<u8>,
}

/// The icon WebKit has for the page `view` shows, given to `done`; nothing
/// when it has none (yet).
pub fn fetch(view: &wpe_webkit::WebView, done: impl FnOnce(Icon) + 'static) {
    let Some(uri) = view.uri().filter(|u| u.starts_with("http")) else { return };
    let Some(database) = view.network_session().and_then(|s| s.website_data_manager()).and_then(|m| m.favicon_database()) else {
        return;
    };
    database.page_icons(&uri, None::<&wpe_webkit::gio::Cancellable>, move |result| {
        let Ok(list) = result else { return };
        // The smallest that is big enough, else the biggest.
        let images: Vec<wpe_webkit::Image> = (0..list.length()).filter_map(|i| list.get(i)).collect();
        let best = images
            .iter()
            .filter(|i| i.width() >= SIZE)
            .min_by_key(|i| i.width())
            .or_else(|| images.iter().max_by_key(|i| i.width()));
        if let Some(icon) = best.and_then(from_image) {
            done(icon);
        }
    });
}

/// WebKit's image (BGRA, premultiplied) as an icon, scaled down to fit.
fn from_image(image: &wpe_webkit::Image) -> Option<Icon> {
    let (width, height, stride) = (image.width(), image.height(), image.stride() as usize);
    if width <= 0 || height <= 0 {
        return None;
    }
    let bytes = image.as_bytes()?;
    let data: &[u8] = &bytes;
    let scale = (width.max(height) as f64 / SIZE as f64).max(1.0);
    let (w, h) = (((width as f64 / scale).round() as i32).max(1), ((height as f64 / scale).round() as i32).max(1));
    let mut rgba = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            // The average of the pixels this one covers.
            let (x0, x1) = ((x as f64 * scale) as i32, (((x + 1) as f64 * scale) as i32).clamp(1, width));
            let (y0, y1) = ((y as f64 * scale) as i32, (((y + 1) as f64 * scale) as i32).clamp(1, height));
            let mut sum = [0u32; 4];
            let mut count = 0u32;
            for sy in y0..y1.max(y0 + 1) {
                for sx in x0..x1.max(x0 + 1) {
                    let at = sy as usize * stride + sx as usize * 4;
                    let Some(p) = data.get(at..at + 4) else { continue };
                    for c in 0..4 {
                        sum[c] += p[c] as u32;
                    }
                    count += 1;
                }
            }
            let count = count.max(1);
            let (b, g, r, a) = (sum[0] / count, sum[1] / count, sum[2] / count, sum[3] / count);
            // Premultiplied to straight alpha.
            let straight = |c: u32| (c * 255).checked_div(a).map_or(0, |v| v.min(255) as u8);
            rgba.extend_from_slice(&[straight(r), straight(g), straight(b), a as u8]);
        }
    }
    Some(Icon { width: w, height: h, rgba })
}
