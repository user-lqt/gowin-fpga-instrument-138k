# MCP3008/FSR simulation

`tb_pressure_adc.v` models an MCP3008 mode-0 response on CH0 and checks:

- the 17-clock single-ended transaction;
- 10-bit data alignment;
- first-sample initialization;
- EMA filtering and calibrated 16-bit modulation output.

`tb_expression_mapper.v` checks the calibrated deadband, full-scale clamp and
optional sensor fault window independently from the SPI sampler.

The testbench uses short divider values so it can run quickly. The hardware
defaults in `pressure_adc.v` are 12.288 MHz input clock, 500 kHz SPI clock and
1 kS/s sampling.
