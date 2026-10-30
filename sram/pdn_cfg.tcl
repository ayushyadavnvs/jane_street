# PDN for the SRAM program memory (D62, a proposal) on Tiny Tapeout IHP sg13cmos5l.
#
# This is LibreLane 3.1.0.dev4's scripts/openroad/common/pdn_cfg.tcl (the version that
# tt-gds-action@ttihp27a installs) for FP_PDN_MULTILAYER 0, with its macro grid removed and a
# wrapper around pdngen. The method is the one tt_um_loom and
# TeslaCoilerOW/ttihp-protocol-emulator took through the Tiny Tapeout gds, precheck and gl_test
# jobs; see sram/README.md for the sources.
#
# Why: a user block on sg13cmos5l may use Metal1-Metal4 only (TopMetal1 belongs to the chip),
# so its PDN is vertical Metal4 stripes. The SRAM's supply pins (VDD!, VDDARRAY!, VSS!) are
# vertical Metal4 columns too. Two shapes on the same layer cannot be joined by a via, so the
# default macro grid (Metal4 to TopMetal1) is empty here. Instead, the stripe pitch and offset
# in config.json put a stripe straight on top of same-net pin columns of each macro
# (sram/check_sram_floorplan.py checks this before a run, and the check below in the run).
# pdngen cuts stripes at fixed macros, so the wrapper releases the macros while it draws them.

source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

set secondary []
foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if { $vdd != $::env(VDD_NET)} {
        lappend secondary $vdd
        set db_net [[ord::get_db_block] findNet $vdd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $vdd]
            $net setSpecial
            $net setSigType "POWER"
        }
    }
    if { $gnd != $::env(GND_NET)} {
        lappend secondary $gnd
        set db_net [[ord::get_db_block] findNet $gnd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $gnd]
            $net setSpecial
            $net setSigType "GROUND"
        }
    }
}

set_voltage_domain -name CORE -power $::env(VDD_NET) -ground $::env(GND_NET) \
    -secondary_power $secondary

# Standard-cell grid: Metal4 stripes only (FP_PDN_MULTILAYER 0), which are the block's pins.
set arg_list [list]
if { $::env(PDN_ENABLE_PINS) } {
    lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER)"
}
define_pdn_grid \
    -name stdcell_grid \
    -starts_with POWER \
    -voltage_domain CORE \
    {*}$arg_list

set arg_list [list]
append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary
add_pdn_stripe \
    -grid stdcell_grid \
    -layer $::env(PDN_VERTICAL_LAYER) \
    -width $::env(PDN_VWIDTH) \
    -pitch $::env(PDN_VPITCH) \
    -offset $::env(PDN_VOFFSET) \
    -spacing $::env(PDN_VSPACING) \
    -starts_with POWER \
    {*}$arg_list

if { $::env(PDN_ENABLE_RAILS) == 1 } {
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) \
        -followpins
    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)"
}

# No macro grid (see the top of this file).

# Every Metal4 stripe shape over a macro must lie on supply pins of its own net, and every
# supply pin of every macro must be touched by a stripe of its net. Stops the flow at
# OpenROAD.GeneratePDN, minutes into a run, if the floorplan and the stripe grid disagree.
proc pbe_sram_check_stripes {} {
    set block [ord::get_db_block]
    set layer $::env(PDN_VERTICAL_LAYER)
    set errors 0
    foreach inst [$block getInsts] {
        if { ![[$inst getMaster] isBlock] } { continue }
        set ib [$inst getBBox]
        set pins [list]
        set hit [dict create]
        foreach iterm [$inst getITerms] {
            set sig [[$iterm getMTerm] getSigType]
            if { $sig ne "POWER" && $sig ne "GROUND" } { continue }
            set net [$iterm getNet]
            if { $net eq "NULL" } {
                puts "PBESRAM ERROR: [$inst getName]/[[$iterm getMTerm] getName] has no net (PDN_MACRO_CONNECTIONS)"
                incr errors
                continue
            }
            dict set hit [$iterm getMTerm] 0
            foreach {x0 y0 x1 y1} [pbe_sram_iterm_rects $inst $iterm $layer] {
                lappend pins [list [$net getName] [$iterm getMTerm] $x0 $y0 $x1 $y1]
            }
        }
        foreach net [concat $::env(VDD_NETS) $::env(GND_NETS)] {
            set dbnet [$block findNet $net]
            foreach sw [$dbnet getSWires] {
                foreach box [$sw getWires] {
                    if { [$box isVia] || [[$box getTechLayer] getName] ne $layer } { continue }
                    set x0 [$box xMin]; set x1 [$box xMax]
                    set y0 [expr {max([$box yMin], [$ib yMin])}]
                    set y1 [expr {min([$box yMax], [$ib yMax])}]
                    if { $x1 <= [$ib xMin] || $x0 >= [$ib xMax] || $y1 <= $y0 } { continue }
                    # covered: the stripe's x span lies inside a same-net pin column; the
                    # VDD!/VDDARRAY! split (no Metal4 in the GDS there) is the only gap allowed
                    set ok 0
                    foreach p $pins {
                        lassign $p pnet mterm px0 py0 px1 py1
                        if { $px0 <= $x0 && $x1 <= $px1 && $py1 > $y0 && $py0 < $y1 } {
                            if { $pnet ne $net } {
                                puts "PBESRAM ERROR: $net stripe at x [expr {$x0 / 1000.0}] lies on [$inst getName]/[$mterm getName] ($pnet)"
                                incr errors
                            } else {
                                set ok 1
                                dict set hit $mterm 1
                            }
                        }
                    }
                    if { !$ok } {
                        puts "PBESRAM ERROR: $net stripe at x [expr {$x0 / 1000.0}] crosses [$inst getName] off its supply pins"
                        incr errors
                    }
                }
            }
        }
        dict for {mterm n} $hit {
            if { !$n } {
                puts "PBESRAM ERROR: no stripe on [$inst getName]/[$mterm getName]"
                incr errors
            }
        }
        puts "PBESRAM [$inst getName]: checked"
    }
    if { $errors } { error "PBESRAM: $errors error(s) in the SRAM power hookup" }
}

# The ITerm's pin rectangles on one layer, in die coordinates (orientations N and FS only:
# they keep the columns vertical and in place).
proc pbe_sram_iterm_rects {inst iterm layer} {
    set ib [$inst getBBox]
    set orient [$inst getOrient]
    if { $orient ne "R0" && $orient ne "MX" } {
        error "PBESRAM: [$inst getName] has orientation $orient; use N or FS"
    }
    set out [list]
    foreach mpin [[$iterm getMTerm] getMPins] {
        foreach box [$mpin getGeometry] {
            if { [$box isVia] || [[$box getTechLayer] getName] ne $layer } { continue }
            set x0 [expr {[$ib xMin] + [$box xMin]}]
            set x1 [expr {[$ib xMin] + [$box xMax]}]
            if { $orient eq "R0" } {
                set y0 [expr {[$ib yMin] + [$box yMin]}]
                set y1 [expr {[$ib yMin] + [$box yMax]}]
            } else {
                set y0 [expr {[$ib yMax] - [$box yMax]}]
                set y1 [expr {[$ib yMax] - [$box yMin]}]
            }
            lappend out $x0 $y0 $x1 $y1
        }
    }
    return $out
}

# LibreLane's pdn.tcl runs `pdngen` (with -skip_trim if PDN_SKIPTRIM) after sourcing this
# file. OpenROAD's pdngen is: check_setup, build_grids, write_to_db, reset_shapes. check_setup
# needs the macros FIXED; build_grids cuts the stripes at FIXED instances. So this runs the
# same steps and marks the macros PLACED only around build_grids.
if { [info commands ::pbe_sram_pdngen] eq "" } {
    rename ::pdngen ::pbe_sram_pdngen
    proc ::pdngen { args } {
        foreach a $args {
            if { $a ne "-skip_trim" } { return [::pbe_sram_pdngen {*}$args] }
        }
        set trim [expr {[lsearch -exact $args -skip_trim] < 0}]
        ::pdn::check_setup
        set released [list]
        foreach inst [[ord::get_db_block] getInsts] {
            if { [[$inst getMaster] isBlock] && [$inst isFixed] } {
                lappend released [list $inst [$inst getPlacementStatus]]
                $inst setPlacementStatus "PLACED"
            }
        }
        set rc [catch { ::pdn::build_grids $trim } msg opts]
        foreach r $released {
            lassign $r inst status
            $inst setPlacementStatus $status
        }
        if { $rc } { return -options $opts $msg }
        ::pdn::write_to_db 1 ""
        ::pdn::reset_shapes
        pbe_sram_check_stripes
    }
}
