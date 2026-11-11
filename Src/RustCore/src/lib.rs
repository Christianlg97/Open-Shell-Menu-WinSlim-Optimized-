//! Owned Windows/COM objects stay in C++. These bounded, allocation-free operations
//! borrow buffers only for the duration of a call. No Rust allocation crosses FFI.
use std::{panic::catch_unwind, slice};

const INVALID_SPAN: u64 = u64::MAX;
const MAX_TEXT: usize = 16 * 1024 * 1024 + 1; // include the C++ terminator slot

fn checked_span(count: i32, unit: u32, limit: u32, remaining: u64) -> Option<u64> {
    let count = u32::try_from(count).ok()?;
    if count > limit || unit == 0 {
        return None;
    }
    let bytes = u64::from(count).checked_mul(u64::from(unit))?;
    (bytes <= remaining).then_some(bytes)
}

#[no_mangle]
pub extern "C" fn WinSlimCheckedSpan(count: i32, unit: u32, limit: u32, remaining: u64) -> u64 {
    catch_unwind(|| checked_span(count, unit, limit, remaining).unwrap_or(INVALID_SPAN))
        .unwrap_or(INVALID_SPAN)
}

#[no_mangle]
pub extern "C" fn WinSlimBitmapBytes(width: i32, height: i32) -> u32 {
    catch_unwind(|| {
        let (Ok(w), Ok(h)) = (u32::try_from(width), u32::try_from(height)) else {
            return 0;
        };
        if w == 0 || h == 0 || w > 4096 || h > 4096 {
            return 0;
        }
        w.checked_mul(h).and_then(|n| n.checked_mul(4)).unwrap_or(0)
    })
    .unwrap_or(0)
}

unsafe fn utf16<'a>(ptr: *const u16, len: usize) -> Option<&'a [u16]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() || len > MAX_TEXT || (ptr as usize) % std::mem::align_of::<u16>() != 0 {
        return None;
    }
    // SAFETY: the C ABI requires a readable buffer of len UTF-16 code units.
    Some(unsafe { slice::from_raw_parts(ptr, len) })
}

fn valid_pidl(bytes: &[u8]) -> bool {
    if bytes.len() < 2 || bytes.len() > 65536 {
        return false;
    }
    let mut at = 0usize;
    while let Some(header) = bytes.get(at..at.saturating_add(2)) {
        let size = usize::from(u16::from_le_bytes([header[0], header[1]]));
        if size == 0 {
            return at + 2 == bytes.len();
        }
        if size < 2 {
            return false;
        }
        let Some(next) = at.checked_add(size) else {
            return false;
        };
        if next > bytes.len() {
            return false;
        }
        at = next;
    }
    false
}

/// # Safety
/// `ptr` must reference `len` readable bytes for this call.
#[no_mangle]
pub unsafe extern "C" fn WinSlimValidatePidl(ptr: *const u8, len: usize) -> i32 {
    catch_unwind(|| {
        if ptr.is_null() || !(2..=65536).contains(&len) {
            return 0;
        }
        // SAFETY: checked size; readable storage is the caller's ABI obligation.
        i32::from(valid_pidl(unsafe { slice::from_raw_parts(ptr, len) }))
    })
    .unwrap_or(0)
}

fn next_line(text: &[u16], mut at: usize) -> Option<(usize, usize, usize)> {
    while at < text.len() && text[at] != 0 {
        let mut start = at;
        while at < text.len() && !matches!(text[at], 0 | 10 | 13) {
            at += 1;
        }
        let mut end = at;
        while at < text.len() && matches!(text[at], 10 | 13) {
            at += 1;
        }
        while start < end && matches!(text[start], 9 | 32) {
            start += 1;
        }
        while end > start && matches!(text[end - 1], 9 | 32) {
            end -= 1;
        }
        if start < end && text[start] != b';' as u16 {
            return Some((start, end, at));
        }
    }
    None
}

/// # Safety
/// Input must be readable; output pointers must be distinct, aligned and writable.
#[no_mangle]
pub unsafe extern "C" fn WinSlimNextLine(
    ptr: *const u16,
    len: usize,
    cursor: *mut usize,
    start: *mut usize,
    end: *mut usize,
) -> i32 {
    catch_unwind(|| {
        if cursor.is_null() || start.is_null() || end.is_null() {
            return -1;
        }
        // SAFETY: caller supplies the three valid output slots and input buffer.
        let Some(text) = (unsafe { utf16(ptr, len) }) else {
            return -1;
        };
        let at = unsafe { *cursor };
        if at > text.len() {
            return -1;
        }
        match next_line(text, at) {
            Some((first, last, next)) => {
                unsafe {
                    *start = first;
                    *end = last;
                    *cursor = next;
                }
                1
            }
            None => {
                unsafe {
                    *cursor = len;
                }
                0
            }
        }
    })
    .unwrap_or(-1)
}

#[cfg(windows)]
#[link(name = "kernel32")]
extern "system" {
    fn FindNLSStringEx(
        locale: *const u16,
        flags: u32,
        source: *const u16,
        source_len: i32,
        value: *const u16,
        value_len: i32,
        found: *mut i32,
        version: *const u8,
        reserved: *mut u8,
        sort_handle: isize,
    ) -> i32;
}

#[cfg(windows)]
fn contains(text: &[u16], token: &[u16], prefix: bool) -> bool {
    // Keep the original Windows linguistic rules, including accents and case.
    let locale = std::ptr::null(); // LOCALE_NAME_USER_DEFAULT (empty string is invariant)
    let flags = (if prefix { 0x00100000 } else { 0x00400000 }) | 0x10 | 0x20;
    // SAFETY: the slices live throughout this synchronous Windows call.
    unsafe {
        FindNLSStringEx(
            locale,
            flags,
            text.as_ptr(),
            text.len() as i32,
            token.as_ptr(),
            token.len() as i32,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null_mut(),
            0,
        ) >= 0
    }
}

#[cfg(not(windows))]
fn contains(text: &[u16], token: &[u16], prefix: bool) -> bool {
    let text = String::from_utf16_lossy(text).to_lowercase();
    let token = String::from_utf16_lossy(token).to_lowercase();
    if prefix {
        text.starts_with(&token)
    } else {
        text.contains(&token)
    }
}

fn match_text(search: &[u16], text: &[u16], subword: bool) -> bool {
    if text.is_empty() {
        return false;
    }
    search
        .split(|c| *c == 32)
        .filter(|s| !s.is_empty())
        .all(|token| {
            if subword {
                return contains(text, token, false);
            }
            let separators = [32, 9, 46, 44, 36, 38, 91, 93, 123, 125, 40, 41, 59, 124];
            let mut at = 0;
            while at < text.len() {
                while at < text.len() && separators.contains(&text[at]) {
                    at += 1;
                }
                if at < text.len() && contains(&text[at..], token, true) {
                    return true;
                }
                while at < text.len() && !separators.contains(&text[at]) {
                    at += 1;
                }
            }
            false
        })
}

/// # Safety
/// Both buffers must be readable for their stated UTF-16 lengths.
#[no_mangle]
pub unsafe extern "C" fn WinSlimMatchText(
    search: *const u16,
    search_len: usize,
    text: *const u16,
    text_len: usize,
    subword: i32,
) -> i32 {
    catch_unwind(|| {
        // SAFETY: lengths are bounded and input validity is the caller's contract.
        let Some(search) = (unsafe { utf16(search, search_len) }) else {
            return 0;
        };
        let Some(text) = (unsafe { utf16(text, text_len) }) else {
            return 0;
        };
        i32::from(match_text(search, text, subword != 0))
    })
    .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    #[test]
    fn reject_corrupt_cache_lengths() {
        assert_eq!(checked_span(-1, 2, 32767, u64::MAX), None);
        assert_eq!(checked_span(i32::MAX, 2, 32767, u64::MAX), None);
        assert_eq!(checked_span(8, 2, 32767, 15), None);
        assert_eq!(checked_span(8, 2, 32767, 16), Some(16));
        assert_eq!(WinSlimBitmapBytes(65536, 65537), 0);
        assert_eq!(WinSlimBitmapBytes(-1, 32), 0);
        assert_eq!(WinSlimBitmapBytes(48, 48), 9216);
    }

    #[test]
    fn reject_malformed_pidls() {
        assert!(valid_pidl(&[0, 0]));
        assert!(valid_pidl(&[4, 0, 1, 2, 0, 0]));
        for bad in [&[1, 0][..], &[8, 0, 0, 0], &[0, 0, 1], &[2, 0]] {
            assert!(!valid_pidl(bad));
        }
    }

    #[test]
    fn parse_mixed_newlines_comments_and_whitespace() {
        let text = wide(" ; comment\r\n\tName=Música \t\n\r Value=🛡️\rLast=1\0");
        let mut at = 0;
        let mut lines = Vec::new();
        while let Some((start, end, next)) = next_line(&text, at) {
            lines.push(String::from_utf16(&text[start..end]).unwrap());
            at = next;
        }
        assert_eq!(lines, ["Name=Música", "Value=🛡️", "Last=1"]);
    }

    #[test]
    fn match_multiple_tokens_and_word_boundaries() {
        let text = wide("Windows PowerShell");
        assert!(match_text(&wide("win power"), &text, false));
        assert!(match_text(&wide("shell"), &text, true));
        assert!(!match_text(&wide("shell"), &text, false));
        assert!(!match_text(&wide("win missing"), &text, true));
        assert!(!match_text(&wide("win"), &[], true));
        let long = "x".repeat(200);
        assert!(match_text(&wide(&long), &wide(&long), true));
    }

    #[test]
    #[cfg(windows)]
    fn preserve_windows_accent_insensitive_matching() {
        assert!(match_text(&wide("musica"), &wide("MÚSICA"), true));
        assert!(match_text(&wide("config"), &wide("Configuración"), false));
    }

    #[test]
    fn ffi_rejects_null_buffers() {
        assert_eq!(unsafe { WinSlimValidatePidl(std::ptr::null(), 2) }, 0);
        assert_eq!(
            unsafe { WinSlimMatchText(std::ptr::null(), 1, std::ptr::null(), 1, 1) },
            0
        );
    }
}
