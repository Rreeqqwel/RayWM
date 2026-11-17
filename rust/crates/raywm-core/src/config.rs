//! Validated policy snapshots, independent of runtime and protocol state.
//! No file format or Lua host is introduced here.

use std::{error::Error, fmt};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Configuration {
    pub floating: FloatingConfig,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FloatingConfig {
    pub cascade_step: u32,
    pub cascade_slots: u32,
    pub secondary_percent: u32,
}

impl Default for FloatingConfig {
    fn default() -> Self {
        Self {
            cascade_step: 48,
            cascade_slots: 5,
            secondary_percent: 60,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConfigError {
    CascadeStep,
    CascadeSlots,
    SecondaryPercent,
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::CascadeStep => "cascade step must be at most 4096 pixels",
            Self::CascadeSlots => "cascade slots must be between 1 and 256",
            Self::SecondaryPercent => "secondary window percent must be between 1 and 100",
        })
    }
}
impl Error for ConfigError {}

impl Configuration {
    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.floating.cascade_step > 4096 {
            return Err(ConfigError::CascadeStep);
        }
        if !(1..=256).contains(&self.floating.cascade_slots) {
            return Err(ConfigError::CascadeSlots);
        }
        if !(1..=100).contains(&self.floating.secondary_percent) {
            return Err(ConfigError::SecondaryPercent);
        }
        Ok(())
    }
}
