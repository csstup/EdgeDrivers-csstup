2022/12/26 - V0.92 - 2022-12-28T15:58:42.260595216
- Fixed issue where the driver wasn't requesting the correct 
  power/voltage values if monitoring was disabled.
- Fixed issue where the reporting schedule was not configured
  properly if the driver reinitialized.
- Fixed issue if the driver was changed to another driver 
  and back to this one, the reporting and divisor data was 
  not properly setup.

2022/12/23 - V0.91
- Added single decimal point rounding to power and current values.
