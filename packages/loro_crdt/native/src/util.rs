//! ABI plumbing shared by every exported function.
//!
//! The ABI is deliberately narrow so the same exports work through `dart:ffi`
//! on native platforms and through `wasm_ffi` on the web:
//!
//! * Only `int32_t`, `uint32_t`, `double` and pointers cross the boundary. No
//!   structs by value, no 64-bit integers (dart2js cannot represent them), no
//!   callbacks.
//! * Inputs are borrowed `(ptr, len)` byte ranges that the caller allocated with
//!   [`loro_alloc`] and frees with [`loro_dealloc`].
//! * Outputs that are not scalars or handles are returned as an owned buffer:
//!   a pointer to `[u32 little-endian length][payload]`, freed with
//!   [`loro_buf_free`].
//! * Every fallible function takes a trailing `err` slot. On failure an owned
//!   buffer holding `[str code][str message]` is stored into `*err` and the
//!   function returns a zero/null value.

use std::fmt::{Debug, Display};
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::codec::Writer;

pub type ErrSlot = *mut *mut u8;

pub struct FfiError {
    pub code: String,
    pub message: String,
}

impl FfiError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new("InvalidArgument", message)
    }

    fn panic(payload: Box<dyn std::any::Any + Send>) -> Self {
        let message = if let Some(s) = payload.downcast_ref::<&str>() {
            (*s).to_string()
        } else if let Some(s) = payload.downcast_ref::<String>() {
            s.clone()
        } else {
            "unknown panic".to_string()
        };
        Self::new("Panic", message)
    }
}

/// Every error type loro returns implements `Error`, so `?` works directly.
/// The code is the enum variant name taken from the `Debug` output, which lets
/// Dart distinguish e.g. `OutOfBound` from `ImportUnsupportedEncodingMode`.
impl<E: std::error::Error> From<E> for FfiError {
    fn from(e: E) -> Self {
        FfiError::new(variant_name(&e), e.to_string())
    }
}

fn variant_name<E: Debug>(e: &E) -> String {
    let dbg = format!("{e:?}");
    let name: String = dbg
        .chars()
        .take_while(|c| c.is_alphanumeric() || *c == '_')
        .collect();
    if name.is_empty() {
        "LoroError".to_string()
    } else {
        name
    }
}

pub fn err_msg(message: impl Display) -> FfiError {
    FfiError::invalid(message.to_string())
}

pub type FfiResult<T> = Result<T, FfiError>;

/// Value returned to the caller when a function fails.
pub trait FfiDefault {
    fn ffi_default() -> Self;
}

impl FfiDefault for () {
    fn ffi_default() -> Self {}
}
impl FfiDefault for i32 {
    fn ffi_default() -> Self {
        0
    }
}
impl FfiDefault for u32 {
    fn ffi_default() -> Self {
        0
    }
}
impl FfiDefault for f64 {
    fn ffi_default() -> Self {
        0.0
    }
}
impl<T> FfiDefault for *mut T {
    fn ffi_default() -> Self {
        std::ptr::null_mut()
    }
}
impl<T> FfiDefault for *const T {
    fn ffi_default() -> Self {
        std::ptr::null()
    }
}

/// Runs `f`, converting both errors and panics into an entry in `err`.
pub fn guard<R: FfiDefault>(err: ErrSlot, f: impl FnOnce() -> FfiResult<R>) -> R {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => {
            write_err(err, e);
            R::ffi_default()
        }
        Err(payload) => {
            write_err(err, FfiError::panic(payload));
            R::ffi_default()
        }
    }
}

/// Like [`guard`] for functions without an error slot (destructors): a panic
/// must never unwind across the boundary, so it is swallowed.
pub fn guard_silent(f: impl FnOnce()) {
    let _ = catch_unwind(AssertUnwindSafe(f));
}

fn write_err(err: ErrSlot, e: FfiError) {
    if err.is_null() {
        return;
    }
    let mut w = Writer::new();
    w.str(&e.code);
    w.str(&e.message);
    unsafe {
        let prev = *err;
        if !prev.is_null() {
            loro_buf_free(prev);
        }
        *err = w.finish();
    }
}

/// Borrows a caller-provided byte range.
pub unsafe fn bytes<'a>(ptr: *const u8, len: u32) -> &'a [u8] {
    if len == 0 || ptr.is_null() {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len as usize)
    }
}

/// Borrows a caller-provided UTF-8 string.
pub unsafe fn str<'a>(ptr: *const u8, len: u32) -> FfiResult<&'a str> {
    std::str::from_utf8(bytes(ptr, len)).map_err(|e| FfiError::invalid(e.to_string()))
}

/// Borrows the value behind an opaque handle.
pub unsafe fn handle<'a, T>(ptr: *const T) -> FfiResult<&'a T> {
    ptr.as_ref().ok_or_else(|| FfiError::invalid("null handle"))
}

pub fn into_handle<T>(value: T) -> *mut T {
    Box::into_raw(Box::new(value))
}

pub unsafe fn free_handle<T>(ptr: *mut T) {
    if !ptr.is_null() {
        guard_silent(|| drop(Box::from_raw(ptr)));
    }
}

/// Allocates `len` zeroed bytes that the caller fills with input data.
#[no_mangle]
pub extern "C" fn loro_alloc(len: u32) -> *mut u8 {
    let boxed = vec![0u8; len as usize].into_boxed_slice();
    Box::into_raw(boxed) as *mut u8
}

/// Frees memory returned by [`loro_alloc`]; `len` must match.
#[no_mangle]
pub unsafe extern "C" fn loro_dealloc(ptr: *mut u8, len: u32) {
    if ptr.is_null() {
        return;
    }
    let slice = std::ptr::slice_from_raw_parts_mut(ptr, len as usize);
    drop(Box::from_raw(slice));
}

/// Frees an owned output buffer (`[u32 len][payload]`).
#[no_mangle]
pub unsafe extern "C" fn loro_buf_free(ptr: *mut u8) {
    if ptr.is_null() {
        return;
    }
    let len = u32::from_le_bytes([*ptr, *ptr.add(1), *ptr.add(2), *ptr.add(3)]) as usize;
    let slice = std::ptr::slice_from_raw_parts_mut(ptr, len + 4);
    drop(Box::from_raw(slice));
}
