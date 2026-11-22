//! Mobile Config (MCInstall)
//!
//! Read access to the device's cloud configuration through the
//! MCInstall service — the same service Apple Configurator and MDM
//! use, and the one desktop tooling (pymobiledevice3's
//! MobileConfigService, Nugget's device manager) reads the live
//! cloud configuration from with a single
//! `{"RequestType": "GetCloudConfiguration"}` exchange.
//!
//! Drift only ever reads: there is deliberately no setter here, and
//! no profile install/remove surface. The fetched dictionary is
//! merged host-side and delivered through the ordinary backup
//! restore, exactly as the desktop original does it.

use crate::{Idevice, IdeviceError, IdeviceService, obf};

/// Client for interacting with the Mobile Config service
#[derive(Debug)]
pub struct MobileConfigClient {
    /// The underlying device connection with established service
    pub idevice: Idevice,
}

impl IdeviceService for MobileConfigClient {
    /// Returns the service name as registered with lockdownd
    fn service_name() -> std::borrow::Cow<'static, str> {
        obf!("com.apple.mobile.MCInstall")
    }

    async fn from_stream(idevice: Idevice) -> Result<Self, crate::IdeviceError> {
        Ok(Self::new(idevice))
    }
}

impl MobileConfigClient {
    /// Creates a new client from an existing device connection
    ///
    /// # Arguments
    /// * `idevice` - Pre-established device connection
    pub fn new(idevice: Idevice) -> Self {
        Self { idevice }
    }

    /// Fetches the device's cloud configuration
    ///
    /// # Returns
    /// The `CloudConfiguration` dictionary from the device's reply,
    /// or None when the reply carries none (the device has no cloud
    /// configuration stored)
    pub async fn get_cloud_configuration(
        &mut self,
    ) -> Result<Option<plist::Dictionary>, IdeviceError> {
        let req = crate::plist!({
            "RequestType": "GetCloudConfiguration",
        });
        self.idevice.send_plist(req).await?;
        let mut res = self.idevice.read_plist().await?;

        Ok(res
            .remove("CloudConfiguration")
            .and_then(|x| x.into_dictionary()))
    }
}

#[cfg(feature = "rsd")]
impl crate::RsdService for MobileConfigClient {
    fn rsd_service_name() -> std::borrow::Cow<'static, str> {
        crate::obf!("com.apple.mobile.MCInstall.shim.remote")
    }
    async fn from_stream(stream: Box<dyn crate::ReadWrite>) -> Result<Self, crate::IdeviceError> {
        let mut idevice = crate::Idevice::new(stream, "");
        idevice.rsd_checkin().await?;
        Ok(Self::new(idevice))
    }
}
