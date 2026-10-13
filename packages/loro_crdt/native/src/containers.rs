use loro::cursor::{PosType, Side};
use loro::{
    Container, ContainerTrait, LoroCounter, LoroList, LoroMap, LoroMovableList, LoroText, LoroTree,
    LoroValue, TreeID, TreeParentId, UpdateOptions,
};

use crate::codec::{container_type_code, container_type_from_code, encode, side_from_i32, Reader, Writer};
use crate::doc::{new_container, new_doc, LoroContainerHandle, LoroDocHandle};
use crate::util::{bytes, err_msg, free_handle, guard, handle, str, ErrSlot, FfiError, FfiResult};

unsafe fn container<'a>(c: *const LoroContainerHandle) -> FfiResult<&'a Container> {
    Ok(&handle(c)?.0)
}

macro_rules! variant {
    ($fn:ident, $variant:ident, $ty:ty, $name:literal) => {
        unsafe fn $fn<'a>(c: *const LoroContainerHandle) -> FfiResult<&'a $ty> {
            match container(c)? {
                Container::$variant(x) => Ok(x),
                other => Err(FfiError::invalid(format!(
                    concat!("expected a ", $name, " container, got {:?}"),
                    other.get_type()
                ))),
            }
        }
    };
}

variant!(text, Text, LoroText, "Text");
variant!(map, Map, LoroMap, "Map");
variant!(movable_list, MovableList, LoroMovableList, "MovableList");
variant!(tree, Tree, LoroTree, "Tree");
variant!(counter, Counter, LoroCounter, "Counter");

/// `List` and `MovableList` share most operations.
enum AnyList<'a> {
    List(&'a LoroList),
    Movable(&'a LoroMovableList),
}

unsafe fn any_list<'a>(c: *const LoroContainerHandle) -> FfiResult<AnyList<'a>> {
    match container(c)? {
        Container::List(l) => Ok(AnyList::List(l)),
        Container::MovableList(l) => Ok(AnyList::Movable(l)),
        other => Err(FfiError::invalid(format!(
            "expected a List or MovableList container, got {:?}",
            other.get_type()
        ))),
    }
}

unsafe fn value_arg(ptr: *const u8, len: u32) -> FfiResult<LoroValue> {
    let mut r = Reader::new(bytes(ptr, len));
    let v = r.value()?;
    if let LoroValue::Container(_) = v {
        return Err(err_msg(
            "container ids cannot be inserted as values; insert a container instead",
        ));
    }
    Ok(v)
}

/// `0` UTF-16 code units, `1` Unicode code points, `2` UTF-8 bytes.
fn pos_type(code: u32) -> FfiResult<PosType> {
    Ok(match code {
        0 => PosType::Utf16,
        1 => PosType::Unicode,
        2 => PosType::Bytes,
        _ => return Err(err_msg(format!("invalid position type {code}"))),
    })
}

fn write_opt_cursor(w: &mut Writer, c: Option<loro::cursor::Cursor>) {
    match c {
        Some(c) => {
            w.u8(1);
            w.cursor(&c);
        }
        None => w.u8(0),
    }
}

// ---------------------------------------------------------------------------
// Generic container operations

#[no_mangle]
pub unsafe extern "C" fn loro_container_free(c: *mut LoroContainerHandle) {
    free_handle(c)
}

/// Creates a detached container of type `kind`; insert it into an attached
/// container to make it part of a document.
#[no_mangle]
pub extern "C" fn loro_container_new(kind: u32, err: ErrSlot) -> *mut LoroContainerHandle {
    guard(err, || {
        Ok(new_container(Container::new(container_type_from_code(kind)?)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_container_id(c: *const LoroContainerHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let id = container(c)?.id();
        Ok(encode(|w| w.container_id(&id)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_container_type(c: *const LoroContainerHandle, err: ErrSlot) -> u32 {
    guard(err, || Ok(container_type_code(container(c)?.get_type()) as u32))
}

#[no_mangle]
pub unsafe extern "C" fn loro_container_is_attached(c: *const LoroContainerHandle, err: ErrSlot) -> i32 {
    guard(err, || Ok(container(c)?.is_attached() as i32))
}

/// Returns the attached version of a container, or null.
#[no_mangle]
pub unsafe extern "C" fn loro_container_get_attached(
    c: *const LoroContainerHandle,
    err: ErrSlot,
) -> *mut LoroContainerHandle {
    guard(err, || {
        Ok(match container(c)?.get_attached() {
            Some(a) => new_container(a),
            None => std::ptr::null_mut(),
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_container_is_deleted(c: *const LoroContainerHandle, err: ErrSlot) -> i32 {
    guard(err, || Ok(container(c)?.is_deleted() as i32))
}

/// Returns the document owning an attached container, or null.
#[no_mangle]
pub unsafe extern "C" fn loro_container_doc(
    c: *const LoroContainerHandle,
    err: ErrSlot,
) -> *mut LoroDocHandle {
    guard(err, || {
        Ok(match container(c)?.doc() {
            Some(d) => new_doc(d),
            None => std::ptr::null_mut(),
        })
    })
}

fn shallow_value(c: &Container) -> LoroValue {
    match c {
        Container::Text(t) => LoroValue::from(t.to_string()),
        Container::Map(m) => m.get_value(),
        Container::List(l) => l.get_value(),
        Container::MovableList(l) => l.get_value(),
        Container::Tree(t) => t.get_value(),
        Container::Counter(c) => LoroValue::Double(c.get_value()),
        Container::Unknown(_) => LoroValue::Null,
    }
}

fn deep_value(c: &Container) -> LoroValue {
    match c {
        Container::Map(m) => m.get_deep_value(),
        Container::List(l) => l.get_deep_value(),
        Container::MovableList(l) => l.get_deep_value(),
        Container::Tree(t) => t.get_value_with_meta(),
        other => shallow_value(other),
    }
}

#[no_mangle]
pub unsafe extern "C" fn loro_container_get_value(c: *const LoroContainerHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let v = shallow_value(container(c)?);
        Ok(encode(|w| w.value(&v)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_container_get_deep_value(
    c: *const LoroContainerHandle,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let v = deep_value(container(c)?);
        Ok(encode(|w| w.value(&v)))
    })
}

// ---------------------------------------------------------------------------
// Text

#[no_mangle]
pub unsafe extern "C" fn loro_text_insert(
    c: *const LoroContainerHandle,
    pos: u32,
    unit: u32,
    s_ptr: *const u8,
    s_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let t = text(c)?;
        let s = str(s_ptr, s_len)?;
        let pos = pos as usize;
        match pos_type(unit)? {
            PosType::Utf16 => t.insert_utf16(pos, s)?,
            PosType::Unicode => t.insert(pos, s)?,
            _ => t.insert_utf8(pos, s)?,
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_text_delete(
    c: *const LoroContainerHandle,
    pos: u32,
    len: u32,
    unit: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let t = text(c)?;
        let (pos, len) = (pos as usize, len as usize);
        match pos_type(unit)? {
            PosType::Utf16 => t.delete_utf16(pos, len)?,
            PosType::Unicode => t.delete(pos, len)?,
            _ => t.delete_utf8(pos, len)?,
        }
        Ok(())
    })
}

/// Converts a range in `unit` to a range in a unit `slice`/`unmark` accept.
fn to_unicode_range(t: &LoroText, start: u32, end: u32, unit: PosType) -> FfiResult<(usize, usize)> {
    let conv = |i: u32| {
        t.convert_pos(i as usize, unit, PosType::Unicode)
            .ok_or_else(|| FfiError::new("OutOfBound", format!("position {i} is out of bounds")))
    };
    Ok((conv(start)?, conv(end)?))
}

#[no_mangle]
pub unsafe extern "C" fn loro_text_slice(
    c: *const LoroContainerHandle,
    start: u32,
    end: u32,
    unit: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let t = text(c)?;
        let s = match pos_type(unit)? {
            PosType::Utf16 => t.slice_utf16(start as usize, end as usize)?,
            PosType::Unicode => t.slice(start as usize, end as usize)?,
            other => {
                let (a, b) = to_unicode_range(t, start, end, other)?;
                t.slice(a, b)?
            }
        };
        Ok(encode(|w| w.str(&s)))
    })
}

/// Deletes `len` at `pos`, inserts `s`, and returns the deleted text.
#[no_mangle]
pub unsafe extern "C" fn loro_text_splice(
    c: *const LoroContainerHandle,
    pos: u32,
    len: u32,
    unit: u32,
    s_ptr: *const u8,
    s_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let t = text(c)?;
        let s = str(s_ptr, s_len)?;
        let (p, l) = (pos as usize, len as usize);
        let deleted = match pos_type(unit)? {
            PosType::Utf16 => {
                let deleted = t.slice_utf16(p, p + l)?;
                t.splice_utf16(p, l, s)?;
                deleted
            }
            PosType::Unicode => t.splice(p, l, s)?,
            other => {
                let (a, b) = to_unicode_range(t, pos, pos + len, other)?;
                t.splice(a, b - a, s)?
            }
        };
        Ok(encode(|w| w.str(&deleted)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_text_len(c: *const LoroContainerHandle, unit: u32, err: ErrSlot) -> u32 {
    guard(err, || {
        let t = text(c)?;
        Ok(match pos_type(unit)? {
            PosType::Utf16 => t.len_utf16(),
            PosType::Unicode => t.len_unicode(),
            _ => t.len_utf8(),
        } as u32)
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_text_to_string(c: *const LoroContainerHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let s = text(c)?.to_string();
        Ok(encode(|w| w.str(&s)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_text_push(
    c: *const LoroContainerHandle,
    s_ptr: *const u8,
    s_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        text(c)?.push_str(str(s_ptr, s_len)?)?;
        Ok(())
    })
}

/// Replaces the content with `s` using a minimal diff. `timeout_ms < 0`
/// means no timeout.
#[no_mangle]
pub unsafe extern "C" fn loro_text_update(
    c: *const LoroContainerHandle,
    s_ptr: *const u8,
    s_len: u32,
    by_line: i32,
    timeout_ms: f64,
    use_refined_diff: i32,
    err: ErrSlot,
) {
    guard(err, || {
        let t = text(c)?;
        let s = str(s_ptr, s_len)?;
        let options = UpdateOptions {
            timeout_ms: (timeout_ms >= 0.0).then_some(timeout_ms),
            use_refined_diff: use_refined_diff != 0,
        };
        if by_line != 0 {
            t.update_by_line(s, options)
        } else {
            t.update(s, options)
        }
        .map_err(|e| FfiError::new("UpdateTimeout", e.to_string()))?;
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_text_mark(
    c: *const LoroContainerHandle,
    start: u32,
    end: u32,
    unit: u32,
    key_ptr: *const u8,
    key_len: u32,
    value_ptr: *const u8,
    value_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let t = text(c)?;
        let key = str(key_ptr, key_len)?;
        let value = value_arg(value_ptr, value_len)?;
        let range = start as usize..end as usize;
        match pos_type(unit)? {
            PosType::Utf16 => t.mark_utf16(range, key, value)?,
            PosType::Unicode => t.mark(range, key, value)?,
            _ => t.mark_utf8(range, key, value)?,
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_text_unmark(
    c: *const LoroContainerHandle,
    start: u32,
    end: u32,
    unit: u32,
    key_ptr: *const u8,
    key_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let t = text(c)?;
        let key = str(key_ptr, key_len)?;
        match pos_type(unit)? {
            PosType::Utf16 => t.unmark_utf16(start as usize..end as usize, key)?,
            PosType::Unicode => t.unmark(start as usize..end as usize, key)?,
            other => {
                let (a, b) = to_unicode_range(t, start, end, other)?;
                t.unmark(a..b, key)?
            }
        }
        Ok(())
    })
}

/// Returns the rich-text delta (lengths in UTF-16 code units).
#[no_mangle]
pub unsafe extern "C" fn loro_text_to_delta(c: *const LoroContainerHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let d = text(c)?.to_delta();
        Ok(encode(|w| w.text_deltas(&d)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_text_slice_delta(
    c: *const LoroContainerHandle,
    start: u32,
    end: u32,
    unit: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let d = text(c)?.slice_delta(start as usize, end as usize, pos_type(unit)?)?;
        Ok(encode(|w| w.text_deltas(&d)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_text_apply_delta(
    c: *const LoroContainerHandle,
    delta_ptr: *const u8,
    delta_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let d = Reader::new(bytes(delta_ptr, delta_len)).text_deltas()?;
        text(c)?.apply_delta(&d)?;
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_text_get_richtext_value(
    c: *const LoroContainerHandle,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let v = text(c)?.get_richtext_value();
        Ok(encode(|w| w.value(&v)))
    })
}

/// `pos` is in UTF-16 code units. Returns `[u8 has][cursor]`.
#[no_mangle]
pub unsafe extern "C" fn loro_text_get_cursor(
    c: *const LoroContainerHandle,
    pos: u32,
    side: i32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let cursor = text(c)?.get_cursor(pos as usize, side_from_i32(side)?);
        Ok(encode(|w| write_opt_cursor(w, cursor)))
    })
}

/// Returns the converted position, or -1 if `index` is out of bounds.
#[no_mangle]
pub unsafe extern "C" fn loro_text_convert_pos(
    c: *const LoroContainerHandle,
    index: u32,
    from: u32,
    to: u32,
    err: ErrSlot,
) -> i32 {
    guard(err, || {
        Ok(text(c)?
            .convert_pos(index as usize, pos_type(from)?, pos_type(to)?)
            .map_or(-1, |p| p as i32))
    })
}

/// Returns `[u8 has][str peer]` for the peer that inserted the character.
#[no_mangle]
pub unsafe extern "C" fn loro_text_get_editor_at(
    c: *const LoroContainerHandle,
    pos: u32,
    unit: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let t = text(c)?;
        let unicode = t.convert_pos(pos as usize, pos_type(unit)?, PosType::Unicode);
        let peer = unicode.and_then(|p| t.get_editor_at_unicode_pos(p));
        Ok(encode(|w| w.opt_peer(peer)))
    })
}

// ---------------------------------------------------------------------------
// Map

#[no_mangle]
pub unsafe extern "C" fn loro_map_insert(
    c: *const LoroContainerHandle,
    key_ptr: *const u8,
    key_len: u32,
    value_ptr: *const u8,
    value_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        map(c)?.insert(str(key_ptr, key_len)?, value_arg(value_ptr, value_len)?)?;
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_map_delete(
    c: *const LoroContainerHandle,
    key_ptr: *const u8,
    key_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        map(c)?.delete(str(key_ptr, key_len)?)?;
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_map_clear(c: *const LoroContainerHandle, err: ErrSlot) {
    guard(err, || {
        map(c)?.clear()?;
        Ok(())
    })
}

/// Returns a value-or-container, or the absent tag.
#[no_mangle]
pub unsafe extern "C" fn loro_map_get(
    c: *const LoroContainerHandle,
    key_ptr: *const u8,
    key_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let v = map(c)?.get(str(key_ptr, key_len)?);
        Ok(encode(|w| w.opt_value_or_container(v)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_map_len(c: *const LoroContainerHandle, err: ErrSlot) -> u32 {
    guard(err, || Ok(map(c)?.len() as u32))
}

/// Returns the keys in sorted order: `[u32 n](str)*`.
#[no_mangle]
pub unsafe extern "C" fn loro_map_keys(c: *const LoroContainerHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let mut keys: Vec<String> = map(c)?.keys().map(|k| k.to_string()).collect();
        keys.sort_unstable();
        Ok(encode(|w| {
            w.len(keys.len());
            for k in &keys {
                w.str(k);
            }
        }))
    })
}

/// Returns `[u32 n]([str key][value-or-container])*` sorted by key.
#[no_mangle]
pub unsafe extern "C" fn loro_map_entries(c: *const LoroContainerHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let m = map(c)?;
        let mut entries = Vec::with_capacity(m.len());
        m.for_each(|k, v| entries.push((k.to_string(), v)));
        entries.sort_unstable_by(|a, b| a.0.cmp(&b.0));
        Ok(encode(|w| {
            w.len(entries.len());
            for (k, v) in entries {
                w.str(&k);
                w.value_or_container(v);
            }
        }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_map_insert_container(
    c: *const LoroContainerHandle,
    key_ptr: *const u8,
    key_len: u32,
    child: *const LoroContainerHandle,
    err: ErrSlot,
) -> *mut LoroContainerHandle {
    guard(err, || {
        let child = container(child)?.clone();
        Ok(new_container(
            map(c)?.insert_container(str(key_ptr, key_len)?, child)?,
        ))
    })
}

/// Gets or creates a child container that merges with concurrently created
/// containers under the same key on other peers.
#[no_mangle]
pub unsafe extern "C" fn loro_map_ensure_mergeable(
    c: *const LoroContainerHandle,
    key_ptr: *const u8,
    key_len: u32,
    kind: u32,
    err: ErrSlot,
) -> *mut LoroContainerHandle {
    guard(err, || {
        let m = map(c)?;
        let key = str(key_ptr, key_len)?;
        let child = match container_type_from_code(kind)? {
            loro::ContainerType::Text => Container::Text(m.ensure_mergeable_text(key)?),
            loro::ContainerType::Map => Container::Map(m.ensure_mergeable_map(key)?),
            loro::ContainerType::List => Container::List(m.ensure_mergeable_list(key)?),
            loro::ContainerType::MovableList => Container::MovableList(m.ensure_mergeable_movable_list(key)?),
            loro::ContainerType::Tree => Container::Tree(m.ensure_mergeable_tree(key)?),
            loro::ContainerType::Counter => Container::Counter(m.ensure_mergeable_counter(key)?),
            loro::ContainerType::Unknown(_) => return Err(err_msg("unknown container type")),
        };
        Ok(new_container(child))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_map_get_last_editor(
    c: *const LoroContainerHandle,
    key_ptr: *const u8,
    key_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let peer = map(c)?.get_last_editor(str(key_ptr, key_len)?);
        Ok(encode(|w| w.opt_peer(peer)))
    })
}

// ---------------------------------------------------------------------------
// List and MovableList

#[no_mangle]
pub unsafe extern "C" fn loro_list_insert(
    c: *const LoroContainerHandle,
    pos: u32,
    value_ptr: *const u8,
    value_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let v = value_arg(value_ptr, value_len)?;
        match any_list(c)? {
            AnyList::List(l) => l.insert(pos as usize, v)?,
            AnyList::Movable(l) => l.insert(pos as usize, v)?,
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_list_push(
    c: *const LoroContainerHandle,
    value_ptr: *const u8,
    value_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let v = value_arg(value_ptr, value_len)?;
        match any_list(c)? {
            AnyList::List(l) => l.push(v)?,
            AnyList::Movable(l) => l.push(v)?,
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_list_delete(c: *const LoroContainerHandle, pos: u32, len: u32, err: ErrSlot) {
    guard(err, || {
        match any_list(c)? {
            AnyList::List(l) => l.delete(pos as usize, len as usize)?,
            AnyList::Movable(l) => l.delete(pos as usize, len as usize)?,
        }
        Ok(())
    })
}

/// Removes the last element and returns it (absent tag when empty).
#[no_mangle]
pub unsafe extern "C" fn loro_list_pop(c: *const LoroContainerHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let v = match any_list(c)? {
            AnyList::List(l) => l.pop()?.map(loro::ValueOrContainer::Value),
            AnyList::Movable(l) => l.pop()?,
        };
        Ok(encode(|w| w.opt_value_or_container(v)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_list_get(c: *const LoroContainerHandle, pos: u32, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let v = match any_list(c)? {
            AnyList::List(l) => l.get(pos as usize),
            AnyList::Movable(l) => l.get(pos as usize),
        };
        Ok(encode(|w| w.opt_value_or_container(v)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_list_len(c: *const LoroContainerHandle, err: ErrSlot) -> u32 {
    guard(err, || {
        Ok(match any_list(c)? {
            AnyList::List(l) => l.len(),
            AnyList::Movable(l) => l.len(),
        } as u32)
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_list_clear(c: *const LoroContainerHandle, err: ErrSlot) {
    guard(err, || {
        match any_list(c)? {
            AnyList::List(l) => l.clear()?,
            AnyList::Movable(l) => l.clear()?,
        }
        Ok(())
    })
}

/// Returns `[u32 n](value-or-container)*`.
#[no_mangle]
pub unsafe extern "C" fn loro_list_items(c: *const LoroContainerHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let mut items = Vec::new();
        match any_list(c)? {
            AnyList::List(l) => l.for_each(|v| items.push(v)),
            AnyList::Movable(l) => l.for_each(|v| items.push(v)),
        }
        Ok(encode(|w| {
            w.len(items.len());
            for v in items {
                w.value_or_container(v);
            }
        }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_list_insert_container(
    c: *const LoroContainerHandle,
    pos: u32,
    child: *const LoroContainerHandle,
    err: ErrSlot,
) -> *mut LoroContainerHandle {
    guard(err, || {
        let child = container(child)?.clone();
        Ok(new_container(match any_list(c)? {
            AnyList::List(l) => l.insert_container(pos as usize, child)?,
            AnyList::Movable(l) => l.insert_container(pos as usize, child)?,
        }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_list_push_container(
    c: *const LoroContainerHandle,
    child: *const LoroContainerHandle,
    err: ErrSlot,
) -> *mut LoroContainerHandle {
    guard(err, || {
        let child = container(child)?.clone();
        Ok(new_container(match any_list(c)? {
            AnyList::List(l) => l.push_container(child)?,
            AnyList::Movable(l) => l.push_container(child)?,
        }))
    })
}

/// Returns `[u8 has][cursor]`.
#[no_mangle]
pub unsafe extern "C" fn loro_list_get_cursor(
    c: *const LoroContainerHandle,
    pos: u32,
    side: i32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let side: Side = side_from_i32(side)?;
        let cursor = match any_list(c)? {
            AnyList::List(l) => l.get_cursor(pos as usize, side),
            AnyList::Movable(l) => l.get_cursor(pos as usize, side),
        };
        Ok(encode(|w| write_opt_cursor(w, cursor)))
    })
}

/// Returns `[u8 has][id]` of the op that inserted the element (List only).
#[no_mangle]
pub unsafe extern "C" fn loro_list_get_id_at(
    c: *const LoroContainerHandle,
    pos: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let id = match any_list(c)? {
            AnyList::List(l) => l.get_id_at(pos as usize),
            AnyList::Movable(_) => return Err(err_msg("getIdAt is only available on LoroList")),
        };
        Ok(encode(|w| w.opt_id(id)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_movable_list_set(
    c: *const LoroContainerHandle,
    pos: u32,
    value_ptr: *const u8,
    value_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        movable_list(c)?.set(pos as usize, value_arg(value_ptr, value_len)?)?;
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_movable_list_set_container(
    c: *const LoroContainerHandle,
    pos: u32,
    child: *const LoroContainerHandle,
    err: ErrSlot,
) -> *mut LoroContainerHandle {
    guard(err, || {
        let child = container(child)?.clone();
        Ok(new_container(
            movable_list(c)?.set_container(pos as usize, child)?,
        ))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_movable_list_move(
    c: *const LoroContainerHandle,
    from: u32,
    to: u32,
    err: ErrSlot,
) {
    guard(err, || {
        movable_list(c)?.mov(from as usize, to as usize)?;
        Ok(())
    })
}

/// `which`: 0 creator, 1 last mover, 2 last editor. Returns `[u8 has][peer]`.
#[no_mangle]
pub unsafe extern "C" fn loro_movable_list_peer_at(
    c: *const LoroContainerHandle,
    pos: u32,
    which: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let l = movable_list(c)?;
        let pos = pos as usize;
        let peer = match which {
            0 => l.get_creator_at(pos),
            1 => l.get_last_mover_at(pos),
            _ => l.get_last_editor_at(pos),
        };
        Ok(encode(|w| w.opt_peer(peer)))
    })
}

// ---------------------------------------------------------------------------
// Tree

unsafe fn tree_args<'a>(ptr: *const u8, len: u32) -> Reader<'a> {
    Reader::new(bytes(ptr, len))
}

fn parent_of(p: Option<TreeID>) -> TreeParentId {
    match p {
        Some(id) => TreeParentId::Node(id),
        None => TreeParentId::Root,
    }
}

/// `args`: `[u8 has][tree id parent]`. Returns the new node id.
#[no_mangle]
pub unsafe extern "C" fn loro_tree_create(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let parent = tree_args(args_ptr, args_len).tree_parent()?;
        let id = tree(c)?.create(parent_of(parent))?;
        Ok(encode(|w| w.tree_id(id)))
    })
}

/// Like `loro_tree_create`, inserting at `index` among the siblings.
#[no_mangle]
pub unsafe extern "C" fn loro_tree_create_at(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    index: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let parent = tree_args(args_ptr, args_len).tree_parent()?;
        let id = tree(c)?.create_at(parent_of(parent), index as usize)?;
        Ok(encode(|w| w.tree_id(id)))
    })
}

/// `args`: `[tree id target][u8 has][tree id parent]`. `index < 0` appends.
#[no_mangle]
pub unsafe extern "C" fn loro_tree_move(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    index: i32,
    err: ErrSlot,
) {
    guard(err, || {
        let mut r = tree_args(args_ptr, args_len);
        let target = r.tree_id()?;
        let parent = parent_of(r.tree_parent()?);
        let t = tree(c)?;
        if index < 0 {
            t.mov(target, parent)?;
        } else {
            t.mov_to(target, parent, index as usize)?;
        }
        Ok(())
    })
}

/// `args`: `[tree id target][tree id sibling]`.
#[no_mangle]
pub unsafe extern "C" fn loro_tree_move_beside(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    after: i32,
    err: ErrSlot,
) {
    guard(err, || {
        let mut r = tree_args(args_ptr, args_len);
        let target = r.tree_id()?;
        let sibling = r.tree_id()?;
        let t = tree(c)?;
        if after != 0 {
            t.mov_after(target, sibling)?;
        } else {
            t.mov_before(target, sibling)?;
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_tree_delete(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let target = tree_args(args_ptr, args_len).tree_id()?;
        tree(c)?.delete(target)?;
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_tree_get_meta(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    err: ErrSlot,
) -> *mut LoroContainerHandle {
    guard(err, || {
        let target = tree_args(args_ptr, args_len).tree_id()?;
        Ok(new_container(Container::Map(tree(c)?.get_meta(target)?)))
    })
}

/// Returns `[u8 exists][tree parent]`.
#[no_mangle]
pub unsafe extern "C" fn loro_tree_parent(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let target = tree_args(args_ptr, args_len).tree_id()?;
        let parent = tree(c)?.parent(target);
        Ok(encode(|w| match parent {
            Some(p) => {
                w.u8(1);
                w.tree_parent(p);
            }
            None => w.u8(0),
        }))
    })
}

/// `args`: `[u8 has][tree id parent]`. Returns `[u8 has][u32 n](tree id)*`.
#[no_mangle]
pub unsafe extern "C" fn loro_tree_children(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let parent = tree_args(args_ptr, args_len).tree_parent()?;
        let children = tree(c)?.children(parent_of(parent));
        Ok(encode(|w| match children {
            Some(ids) => {
                w.u8(1);
                w.len(ids.len());
                for id in ids {
                    w.tree_id(id);
                }
            }
            None => w.u8(0),
        }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_tree_children_num(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    err: ErrSlot,
) -> i32 {
    guard(err, || {
        let parent = tree_args(args_ptr, args_len).tree_parent()?;
        Ok(tree(c)?.children_num(parent_of(parent)).map_or(-1, |n| n as i32))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_tree_contains(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    err: ErrSlot,
) -> i32 {
    guard(err, || {
        let target = tree_args(args_ptr, args_len).tree_id()?;
        Ok(tree(c)?.contains(target) as i32)
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_tree_is_node_deleted(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    err: ErrSlot,
) -> i32 {
    guard(err, || {
        let target = tree_args(args_ptr, args_len).tree_id()?;
        Ok(tree(c)?.is_node_deleted(&target)? as i32)
    })
}

/// `which`: 0 all nodes, 1 roots. Returns `[u32 n](tree id)*`.
#[no_mangle]
pub unsafe extern "C" fn loro_tree_node_ids(
    c: *const LoroContainerHandle,
    which: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let t = tree(c)?;
        let ids = if which == 0 { t.nodes() } else { t.roots() };
        Ok(encode(|w| {
            w.len(ids.len());
            for id in ids {
                w.tree_id(id);
            }
        }))
    })
}

/// Returns `[u32 n]([tree id][tree parent][str fractional index][u32 index])*`.
#[no_mangle]
pub unsafe extern "C" fn loro_tree_get_nodes(
    c: *const LoroContainerHandle,
    with_deleted: i32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let nodes = tree(c)?.get_nodes(with_deleted != 0);
        Ok(encode(|w| {
            w.len(nodes.len());
            for n in &nodes {
                w.tree_id(n.id);
                w.tree_parent(n.parent);
                w.str(&n.fractional_index.to_string());
                w.len(n.index);
            }
        }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_tree_fractional_index(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let target = tree_args(args_ptr, args_len).tree_id()?;
        let fi = tree(c)?.fractional_index(target);
        Ok(encode(|w| w.opt_str(fi.as_deref())))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_tree_get_last_move_id(
    c: *const LoroContainerHandle,
    args_ptr: *const u8,
    args_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let target = tree_args(args_ptr, args_len).tree_id()?;
        let id = tree(c)?.get_last_move_id(&target);
        Ok(encode(|w| w.opt_id(id)))
    })
}

/// `jitter < 0` disables fractional indexes.
#[no_mangle]
pub unsafe extern "C" fn loro_tree_set_fractional_index(
    c: *const LoroContainerHandle,
    jitter: i32,
    err: ErrSlot,
) {
    guard(err, || {
        let t = tree(c)?;
        if jitter < 0 {
            t.disable_fractional_index();
        } else {
            t.enable_fractional_index(jitter.min(255) as u8);
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_tree_is_fractional_index_enabled(
    c: *const LoroContainerHandle,
    err: ErrSlot,
) -> i32 {
    guard(err, || Ok(tree(c)?.is_fractional_index_enabled() as i32))
}

// ---------------------------------------------------------------------------
// Counter

#[no_mangle]
pub unsafe extern "C" fn loro_counter_increment(c: *const LoroContainerHandle, value: f64, err: ErrSlot) {
    guard(err, || {
        counter(c)?.increment(value)?;
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_counter_value(c: *const LoroContainerHandle, err: ErrSlot) -> f64 {
    guard(err, || Ok(counter(c)?.get_value()))
}
