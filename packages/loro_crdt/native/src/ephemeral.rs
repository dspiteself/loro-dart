use loro::awareness::EphemeralStore;

use crate::codec::{encode, Reader};
use crate::util::{bytes, free_handle, guard, handle, into_handle, str, ErrSlot, FfiError, FfiResult};

pub struct LoroEphemeralHandle(pub EphemeralStore);

pub unsafe fn store<'a>(e: *const LoroEphemeralHandle) -> FfiResult<&'a EphemeralStore> {
    Ok(&handle(e)?.0)
}

/// `timeout_ms`: entries not updated for this long expire.
#[no_mangle]
pub extern "C" fn loro_ephemeral_new(timeout_ms: f64, err: ErrSlot) -> *mut LoroEphemeralHandle {
    guard(err, || {
        Ok(into_handle(LoroEphemeralHandle(EphemeralStore::new(
            timeout_ms as i64,
        ))))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_ephemeral_free(e: *mut LoroEphemeralHandle) {
    free_handle(e)
}

#[no_mangle]
pub unsafe extern "C" fn loro_ephemeral_set(
    e: *const LoroEphemeralHandle,
    key_ptr: *const u8,
    key_len: u32,
    value_ptr: *const u8,
    value_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let value = Reader::new(bytes(value_ptr, value_len)).value()?;
        store(e)?.set(str(key_ptr, key_len)?, value);
        Ok(())
    })
}

/// Returns a value or the absent tag.
#[no_mangle]
pub unsafe extern "C" fn loro_ephemeral_get(
    e: *const LoroEphemeralHandle,
    key_ptr: *const u8,
    key_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let v = store(e)?.get(str(key_ptr, key_len)?);
        Ok(encode(|w| match v {
            Some(v) => w.value(&v),
            None => w.u8(crate::codec::TAG_ABSENT),
        }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_ephemeral_delete(
    e: *const LoroEphemeralHandle,
    key_ptr: *const u8,
    key_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        store(e)?.delete(str(key_ptr, key_len)?);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_ephemeral_keys(e: *const LoroEphemeralHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let mut keys = store(e)?.keys();
        keys.sort_unstable();
        Ok(encode(|w| {
            w.len(keys.len());
            for k in &keys {
                w.str(k);
            }
        }))
    })
}

/// Returns a map value of every live entry.
#[no_mangle]
pub unsafe extern "C" fn loro_ephemeral_get_all_states(
    e: *const LoroEphemeralHandle,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let states: Vec<_> = store(e)?.get_all_states().into_iter().collect();
        Ok(encode(|w| w.value(&loro::LoroValue::Map(states.into()))))
    })
}

/// Encodes every entry if `all != 0`, otherwise only `key`.
#[no_mangle]
pub unsafe extern "C" fn loro_ephemeral_encode(
    e: *const LoroEphemeralHandle,
    key_ptr: *const u8,
    key_len: u32,
    all: i32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let s = store(e)?;
        let data = if all != 0 {
            s.encode_all()
        } else {
            s.encode(str(key_ptr, key_len)?)
        };
        Ok(encode(|w| w.bytes(&data)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_ephemeral_apply(
    e: *const LoroEphemeralHandle,
    data_ptr: *const u8,
    data_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        store(e)?
            .apply(bytes(data_ptr, data_len))
            .map_err(|msg| FfiError::new("DecodeError", msg.to_string()))?;
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_ephemeral_remove_outdated(e: *const LoroEphemeralHandle, err: ErrSlot) {
    guard(err, || {
        store(e)?.remove_outdated();
        Ok(())
    })
}
