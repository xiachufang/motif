//! Windows Job Object ownership for a PTY process tree.
//!
//! ConPTY's child killer terminates the immediate shell. Assigning that shell
//! to a kill-on-close Job Object also covers tools it launched, matching the
//! process-group cleanup motifd gets from Unix PTYs.

use std::io;

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE};

pub(crate) struct ProcessJob {
    handle: HANDLE,
}

// A HANDLE is an opaque kernel object reference. All operations used here are
// thread-safe, and ownership is released exactly once by Drop.
unsafe impl Send for ProcessJob {}
unsafe impl Sync for ProcessJob {}

impl ProcessJob {
    pub(crate) fn assign(pid: u32) -> io::Result<Self> {
        // SAFETY: null security/name pointers request an unnamed Job Object
        // with default security. Every successful handle is closed below or by
        // Drop.
        let job = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if job.is_null() {
            return Err(io::Error::last_os_error());
        }

        let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        // SAFETY: `info` has the exact structure and byte count requested by
        // JobObjectExtendedLimitInformation.
        let configured = unsafe {
            SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                (&info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        };
        if configured == 0 {
            let error = io::Error::last_os_error();
            unsafe { CloseHandle(job) };
            return Err(error);
        }

        // AssignProcessToJobObject requires SET_QUOTA and TERMINATE access.
        let process = unsafe { OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, pid) };
        if process.is_null() {
            let error = io::Error::last_os_error();
            unsafe { CloseHandle(job) };
            return Err(error);
        }
        let assigned = unsafe { AssignProcessToJobObject(job, process) };
        unsafe { CloseHandle(process) };
        if assigned == 0 {
            let error = io::Error::last_os_error();
            unsafe { CloseHandle(job) };
            return Err(error);
        }

        Ok(Self { handle: job })
    }

    pub(crate) fn terminate(&self) {
        // SAFETY: the handle remains owned by self for this call.
        let _ = unsafe { TerminateJobObject(self.handle, 1) };
    }
}

impl Drop for ProcessJob {
    fn drop(&mut self) {
        // KILL_ON_JOB_CLOSE terminates any descendants that survived the
        // shell's normal shutdown.
        unsafe { CloseHandle(self.handle) };
    }
}
