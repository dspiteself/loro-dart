use std::sync::Mutex;

use loro::UndoManager;

use crate::doc::{doc, LoroDocHandle};
use crate::util::{free_handle, guard, handle, into_handle, str, ErrSlot, FfiResult};

pub struct LoroUndoHandle(Mutex<UndoManager>);

unsafe fn with<R>(
    u: *const LoroUndoHandle,
    f: impl FnOnce(&mut UndoManager) -> FfiResult<R>,
) -> FfiResult<R> {
    let mut m = handle(u)?.0.lock().unwrap_or_else(|p| p.into_inner());
    f(&mut m)
}

/// Tracks local changes of `doc` for undo/redo. Remote changes are never
/// undone, but undo steps are transformed so they still apply on top of them.
#[no_mangle]
pub unsafe extern "C" fn loro_undo_new(d: *const LoroDocHandle, err: ErrSlot) -> *mut LoroUndoHandle {
    guard(err, || {
        Ok(into_handle(LoroUndoHandle(Mutex::new(UndoManager::new(doc(d)?)))))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_undo_free(u: *mut LoroUndoHandle) {
    free_handle(u)
}

/// Returns 1 if a step was undone.
#[no_mangle]
pub unsafe extern "C" fn loro_undo_undo(u: *const LoroUndoHandle, err: ErrSlot) -> i32 {
    guard(err, || with(u, |m| Ok(m.undo()? as i32)))
}

/// Returns 1 if a step was redone.
#[no_mangle]
pub unsafe extern "C" fn loro_undo_redo(u: *const LoroUndoHandle, err: ErrSlot) -> i32 {
    guard(err, || with(u, |m| Ok(m.redo()? as i32)))
}

/// `which`: 0 can undo, 1 can redo, 2 undo count, 3 redo count, 4 is paused.
#[no_mangle]
pub unsafe extern "C" fn loro_undo_query(u: *const LoroUndoHandle, which: u32, err: ErrSlot) -> u32 {
    guard(err, || {
        with(u, |m| {
            Ok(match which {
                0 => m.can_undo() as u32,
                1 => m.can_redo() as u32,
                2 => m.undo_count() as u32,
                3 => m.redo_count() as u32,
                _ => m.is_paused() as u32,
            })
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_undo_record_new_checkpoint(u: *const LoroUndoHandle, err: ErrSlot) {
    guard(err, || with(u, |m| Ok(m.record_new_checkpoint()?)))
}

#[no_mangle]
pub unsafe extern "C" fn loro_undo_set_max_undo_steps(u: *const LoroUndoHandle, steps: u32, err: ErrSlot) {
    guard(err, || {
        with(u, |m| {
            m.set_max_undo_steps(steps as usize);
            Ok(())
        })
    })
}

/// Local changes closer together than `ms` are merged into one undo step.
#[no_mangle]
pub unsafe extern "C" fn loro_undo_set_merge_interval(u: *const LoroUndoHandle, ms: f64, err: ErrSlot) {
    guard(err, || {
        with(u, |m| {
            m.set_merge_interval(ms as i64);
            Ok(())
        })
    })
}

/// Commits whose origin starts with `prefix` are not recorded.
#[no_mangle]
pub unsafe extern "C" fn loro_undo_add_exclude_origin_prefix(
    u: *const LoroUndoHandle,
    prefix_ptr: *const u8,
    prefix_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let prefix = str(prefix_ptr, prefix_len)?;
        with(u, |m| {
            m.add_exclude_origin_prefix(prefix);
            Ok(())
        })
    })
}

/// `op`: 0 clear, 1 group start, 2 group end, 3 pause, 4 resume.
#[no_mangle]
pub unsafe extern "C" fn loro_undo_control(u: *const LoroUndoHandle, op: u32, err: ErrSlot) {
    guard(err, || {
        with(u, |m| {
            match op {
                0 => m.clear(),
                1 => m.group_start()?,
                2 => m.group_end(),
                3 => m.pause(),
                _ => m.resume(),
            }
            Ok(())
        })
    })
}
