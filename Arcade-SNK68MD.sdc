derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# fx68k: paths between phi-enabled registers (enables at least 4 clk_sys apart)
set_multicycle_path -start -setup -from [get_keepers *fx68k:*|Ir[*]] -to [get_keepers *fx68k:*|microAddr[*]] 2
set_multicycle_path -start -hold  -from [get_keepers *fx68k:*|Ir[*]] -to [get_keepers *fx68k:*|microAddr[*]] 1
set_multicycle_path -start -setup -from [get_keepers *fx68k:*|Ir[*]] -to [get_keepers *fx68k:*|nanoAddr[*]] 2
set_multicycle_path -start -hold  -from [get_keepers *fx68k:*|Ir[*]] -to [get_keepers *fx68k:*|nanoAddr[*]] 1
set_multicycle_path -start -setup -from {*|nanoLatch[*]}        -to {*|excUnit|alu|pswCcr[*]} 2
set_multicycle_path -start -hold  -from {*|nanoLatch[*]}        -to {*|excUnit|alu|pswCcr[*]} 1
set_multicycle_path -start -setup -from {*|excUnit|alu|oper[*]} -to {*|excUnit|alu|pswCcr[*]} 2
set_multicycle_path -start -hold  -from {*|excUnit|alu|oper[*]} -to {*|excUnit|alu|pswCcr[*]} 1

# SDRAM: chip clock at the SDRAM_CLK pin (PLL outclk 1)
create_generated_clock -name sdram_clk_pin -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] [get_ports {SDRAM_CLK}]
# SDRAM outputs meet the chip's setup / hold (AS4C32M16SB-7 tIS 1.5 ns / tIH 0.8 ns, 0.5 ns board) at its next clock edge
set_output_delay -clock sdram_clk_pin -max  2.0 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock sdram_clk_pin -min -1.3 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
# SDRAM reads: data valid tAC 6.0 ns (CL 2) + 0.5 ns board after an SDRAM_CLK edge, held tOH 2.5 ns (AS4C32M16SB-7)
set_input_delay -clock sdram_clk_pin -max 6.5 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock sdram_clk_pin -min 2.5 [get_ports {SDRAM_DQ[*]}]
# each read word is sampled on the second clk_sys edge after the SDRAM_CLK edge that launched it; hold stays on the next word (default)
set_multicycle_path -end -setup -from [get_ports {SDRAM_DQ[*]}] -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] 2
