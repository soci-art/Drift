// Jackson Coxson

use std::ptr::null_mut;

use idevice::{
    IdeviceError, IdeviceService, RsdService, mobile_config::MobileConfigClient,
    provider::IdeviceProvider,
};
use plist_ffi::plist_t;

use crate::{
    IdeviceFfiError, IdeviceHandle, core_device_proxy::AdapterHandle, ffi_err,
    provider::IdeviceProviderHandle, rsd::RsdHandshakeHandle, run_sync_local,
};

pub struct MobileConfigClientHandle(pub MobileConfigClient);

/// Automatically creates and connects to Mobile Config (MCInstall), returning a client handle
///
/// # Arguments
/// * [`provider`] - An IdeviceProvider
/// * [`client`] - On success, will be set to point to a newly allocated MobileConfigClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `provider` must be a valid pointer to a handle allocated by this library
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mobile_config_client_connect(
    provider: *mut IdeviceProviderHandle,
    client: *mut *mut MobileConfigClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || client.is_null() {
        tracing::error!("Null pointer provided");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let res: Result<MobileConfigClient, IdeviceError> = run_sync_local(async move {
        let provider_ref: &dyn IdeviceProvider = unsafe { &*(*provider).0 };
        // Connect using the reference
        MobileConfigClient::connect(provider_ref).await
    });

    match res {
        Ok(r) => {
            let boxed = Box::new(MobileConfigClientHandle(r));
            unsafe { *client = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => {
            ffi_err!(e)
        }
    }
}

/// Creates a new MobileConfigClient via RSD
///
/// # Arguments
/// * [`provider`] - An adapter created by this library
/// * [`handshake`] - An RSD handshake from the same provider
/// * [`client`] - On success, will be set to point to a newly allocated MobileConfigClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `provider` must be a valid pointer to a handle allocated by this library
/// `handshake` must be a valid pointer to a handle allocated by this library
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mobile_config_client_connect_rsd(
    provider: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    client: *mut *mut MobileConfigClientHandle,
) -> *mut IdeviceFfiError {
    if provider.is_null() || handshake.is_null() || client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let res: Result<MobileConfigClient, IdeviceError> = run_sync_local(async move {
        let provider_ref = unsafe { &mut (*provider).0 };
        let handshake_ref = unsafe { &mut (*handshake).0 };
        MobileConfigClient::connect_rsd(provider_ref, handshake_ref).await
    });

    match res {
        Ok(r) => {
            let boxed = Box::new(MobileConfigClientHandle(r));
            unsafe { *client = Box::into_raw(boxed) };
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Automatically creates and connects to Mobile Config, returning a client handle
///
/// # Arguments
/// * [`socket`] - An IdeviceSocket handle
/// * [`client`] - On success, will be set to point to a newly allocated MobileConfigClient handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `socket` must be a valid pointer to a handle allocated by this library. The socket is consumed,
/// and may not be used again.
/// `client` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mobile_config_client_new(
    socket: *mut IdeviceHandle,
    client: *mut *mut MobileConfigClientHandle,
) -> *mut IdeviceFfiError {
    if socket.is_null() || client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let socket = unsafe { Box::from_raw(socket) }.0;
    let r = MobileConfigClient::new(socket);
    let boxed = Box::new(MobileConfigClientHandle(r));
    unsafe { *client = Box::into_raw(boxed) };
    null_mut()
}

/// Fetches the device's cloud configuration
///
/// # Arguments
/// * `client` - A valid MobileConfigClient handle
/// * `res` - Will be set to a pointer of a plist dictionary node on success
///
/// # Returns
/// An IdeviceFfiError on error, null on success. Note that res can be null on success
/// if the device has no cloud configuration stored.
///
/// # Safety
/// `client` must be a valid pointer to a handle allocated by this library
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mobile_config_client_get_cloud_configuration(
    client: *mut MobileConfigClientHandle,
    res: *mut plist_t,
) -> *mut IdeviceFfiError {
    if client.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let output: Result<Option<plist::Dictionary>, IdeviceError> = run_sync_local(async move {
        let client_ref = unsafe { &mut (*client).0 };
        client_ref.get_cloud_configuration().await
    });

    match output {
        Ok(output) => {
            let output = match output {
                Some(res) => {
                    plist_ffi::PlistWrapper::new_node(plist::Value::Dictionary(res)).into_ptr()
                }
                None => null_mut(),
            };

            unsafe { *res = output }

            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Frees a handle
///
/// # Arguments
/// * [`handle`] - The handle to free
///
/// # Safety
/// `handle` must be a valid pointer to the handle that was allocated by this library,
/// or NULL (in which case this function does nothing)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mobile_config_client_free(handle: *mut MobileConfigClientHandle) {
    if !handle.is_null() {
        tracing::debug!("Freeing MobileConfigClientHandle");
        let _ = unsafe { Box::from_raw(handle) };
    }
}
