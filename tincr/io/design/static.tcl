package provide tincr.io.design 0.0
package require Tcl 8.5
package require tincr.cad.design 0.0
package require tincr.cad.device 0.0
package require tincr.cad.util 0.0

namespace eval ::tincr:: {
    namespace export \
    write_static_resources \
    get_tile_pips \
    get_site_routethroughs \
    write_static_and_routethrough_luts \
    get_static_routes
}

## Identifies <b>used</b> site routethroughs present in a list of tiles 
# (like the tiles of a pblock) and writes these site rouethroughs to the 
# static design export file.
#
# @param tiles List of tiles in the reconfigurable region (pblock)
# @param channel Output file handle
proc ::tincr::get_site_routethroughs { tiles channel } {
    set site_rts [list]
    set nets [get_nets -hierarchical]

    # Get all nodes that are in the tiles we care about and that also have nets
    set nodes [::struct::set intersect [get_nodes -quiet -of_objects $nets] [get_nodes -quiet -of_objects $tiles]]
    
    # Get the list of nets that those nodes deal with
    set nets [get_nets -of_objects $nodes]
    
    # Get a subset of the PIPs that are within the tiles and are used in nets we care about.
    set tile_pips [lsort [get_pips -quiet -of_objects $tiles -filter {!IS_TEST_PIP && !IS_EXCLUDED_PIP}]]
    set net_pips [lsort [get_pips -quiet -of_objects $nets -filter {!IS_TEST_PIP && !IS_EXCLUDED_PIP}]]
    set pips [::struct::set intersect $tile_pips $net_pips]

    foreach pip $pips {
    # If the PIP is within the tiles of the pblock
    set uphill_node [get_nodes -quiet -uphill -of_object $pip]
    set downhill_node [get_nodes -quiet -downhill -of_object $pip]
        
    # A route-through PIP must have an uphill (source) and a downhill (sink) node
    if {$uphill_node != "" && $downhill_node != ""} {
        # If PSEUDO, it's a route-through PIP (and not a "real" PIP).
        if {[get_property IS_PSEUDO $pip]} {
            set src_pin [get_site_pins -of_object [get_nodes -uphill -of_object $pip]]
            #set snk_pin [get_site_pins -of_object [get_nodes -downhill -of_object $pip]]
        #lappend site_rts "[get_sites -of_object $src_pin]([::tincr::site_pins get_info $src_pin name]-[::tincr::site_pins get_info $snk_pin name])" 
        lappend site_rts "[get_sites -of_object $src_pin]"
        }
        }
    }
    # print the site routethroughs to the pr static file
    ::tincr::print_list -header "SITE_RTS" -channel $channel $site_rts
}

## Searches through the given list of tiles, identifies used PIPs, and
# writes these used PIPs to the PR static export file.
#
# @param tiles List of possible tiles with used PIPs (in a reconfigurable region)
# @param channel Output file handle
proc ::tincr::get_used_pips { tiles channel } {
    set used_pips [list]
    set nets [get_nets -hierarchical]

    # Get all nodes that are in the tiles we care about and that also have nets
    set nodes [::struct::set intersect [get_nodes -quiet -of_objects $nets] [get_nodes -quiet -of_objects $tiles]]
    
    # Get the list of nets that those nodes deal with
    set nets [get_nets -of_objects $nodes]
    
    # Now, print out the PIPs of each tile using the list of tiles and the list of nets
    # TODO: Could probably make this faster with a map from tiles -> nets that go through that tile
    foreach tile $tiles {    
    # If I just use -of_objects $nodes, I will probably find VCC PIPs too. (physical nets)
    set tile_pips [get_pips -quiet -filter "TILE == $tile" -of_objects $nets]
    foreach pip $tile_pips {
        lappend used_pips "[get_property NAME $pip]"
    }  
    }
    # print the used PIPs to the pr static file
    ::tincr::print_list -header "USED_PIPS" -channel $channel $used_pips
}

## Searches through the used sites in the reconfigurable region of the design, 
# identifies LUT BELs that are being used as either a routethrough or static 
# source (always outputs 1 or 0), and writes these BELs in the pr static export file.
#
# @param site_list List of <b>used</b> sites in the reconfigurable region.
# @param channel Output file handle
proc write_static_and_routethrough_luts { tiles channel } {
    set vcc_sources [list]
    set gnd_sources [list]
    set routethrough_luts [list]
    set MAX_CONFIG_SIZE 20
    
    # get list of used sites within the reconfigurable region.
    set site_list [get_sites -quiet -filter IS_USED -of_objects $tiles] 
    
    foreach bel [get_bels -quiet -of $site_list -filter {TYPE =~ *LUT* && !IS_USED}] {
    
    set config [get_property CONFIG.EQN $bel]
    
    # skip long config strings...they cannot be static sources or routethroughs
    if { [string length $config] > $MAX_CONFIG_SIZE } {
        continue
    }
    
    if { [regexp {(O[5,6])=(?:\(A6\+~A6\)\*)?\(?1\)? ?} $config -> pin] } { ; # VCC source
        lappend vcc_sources "[get_property NAME $bel]/$pin"
    } elseif { [regexp {(O[5,6])=(?:\(A6\+~A6\)\*)?\(?0\)? ?} $config -> pin] } { ; # GND source
        lappend gnd_sources "[get_property NAME $bel]/$pin"
    } elseif { [regexp {(O[5,6])=(?:\(A6\+~A6\)\*)?\(+(A[1-6])\)+ ?} $config -> outpin inpin] } { ; # LUT routethrough
        lappend routethrough_luts "$bel/$inpin/$outpin"
    }
    }
    
    # In some cases, FFs that are configured as Latches can be used with no cell being placed on the
    # corresponding Flip Flip. Look for this and add them to the routethrough list. (D and Q are always the input/output pin)
    foreach bel [get_bels -quiet -of $site_list -filter {NAME=~*FF* && !IS_USED}] {
    set mode [string trim [get_property CONFIG.LATCH_OR_FF $bel]]
    if {$mode == "LATCH"} {
        lappend routethrough_luts "$bel/D/Q"
    }
    }
    
    # print the gnd sources, vcc sources, and lut routethroughs to the pr static file
    ::tincr::print_list -header "VCC_SOURCES" -channel $channel $vcc_sources
    ::tincr::print_list -header "GND_SOURCES" -channel $channel $gnd_sources
    ::tincr::print_list -header "LUT_RTS" -channel $channel $routethrough_luts
}

#TODO: This code doesn't handle VCC/GND nets properly yet.
proc ::tincr::get_static_routes { nets channel } {	
	foreach net $nets {
	
		if {$net == "const0" || $net == "const1"} {
		    continue
		}
		
	
		# Get the name(s) of the port(s)
		# If the net connects to more than one partition pin, there will be multiple associated ports
	    set ports [get_pins -filter { HD.ASSIGNED_PPLOCS !=  "" } -of_objects [get_nets $net]]
		
		# There is almost definitely a better way to do this part.
		set portNames ""
		foreach port $ports {
			set portNames "$portNames [string replace $port 0 [string first "/" $port]]"
		}
		
		set route_string "STATIC_RT $net $portNames "
		
		# Split report_route_status by lines
		set lines [split [report_route_status -of_objects $net -return_string] "\n"]
		
		foreach line $lines {
			# Trim spaces, *'s, and p (partition pin marker)
			set line [string trim $line " *p"]
			
			# Remove characters starting from the first '(' to the end of the line
			# This is the PIP information
			set start_idx [string first "(" $line] 
			
			if {$start_idx == -1} {
				continue
			}
			
			set line [string replace $line $start_idx end]
			
			# Get rid of other extra characters
			set line [string trim $line " *\["]
			set line [string map {"p" ""} $line]
			set line [string map {"*" ""} $line]
			set line [string map {" " ""} $line]
			
			# Check if the first character is a closing curly brace
			set comparison [string compare -length 1 $line "\}"]
			
			if {$comparison == 0} {
				set line "$line \}"
				set line [string trimleft $line " \}*\[\]"]
			}
			
			# Check if the first character is an opening curly brace
			set comparison [string compare -length 1 $line "\{"]
			if {$comparison == 0} {
				set line "\{ [string range $line 1 end]"
			}
			
			append route_string "$line "
		}
		#puts $route_string
		::tincr::print $channel $route_string
		#lappend static_routes $route_string
			
	}
}

## Prints the static resources for every reconfigurable region (pblock)
# in a static design.
## Searches through a reconfigurable region (a pblock) and writes used resources
# (PIPs, static and routethrough LUTs, and site routethroughs) to the PR static export file
# @param static_dcp path to a DCP checkpoint of a routed static design
# @param pblock the pblock that defines a reconfigurable region
#TODO: Verbose/quiet options
#TODO: Remove duplicate logic (don't get all nets more than once, etc.)
proc ::tincr::write_static_resources { static_dcp pblock filename } {
    set ::tincr::verbose 1

    open_checkpoint $static_dcp
    
    set pblock [get_pblocks $pblock]
    
    # create the static file
    set filename [::tincr::add_extension ".rsc" $filename]
    set channel_out [open $filename w]
    
    # For now, I will assume the user will define the pblock properly in the first place and that 
    # the partial device file will have the same boundaries as the pblock.
    set tile_range [split [get_property GRID_RANGES $pblock] ":"]
    set bott_left_site [get_sites [lindex $tile_range 0]]
    set top_right_site [get_sites [lindex $tile_range 1]]
    
    # Get the range of tiles in the pblock
    set bott_left_tile [get_tiles -of_objects $bott_left_site]
    set top_right_tile [get_tiles -of_objects $top_right_site]
    
    # Get row and column ranges
    set max_row [get_property ROW $bott_left_tile]
    set min_row [get_property ROW $top_right_tile]
    set max_col [get_property COLUMN $top_right_tile]
    set min_col [get_property COLUMN $bott_left_tile]
    
    ::tincr::print_verbose "Pblock Tile Range: Rows $min_row - $max_row, Columns $min_col - $max_col"
        
    # 1. Get used PIPs.
    # Get a list of tiles that might have used PIPs (CLB and INT)
    # Interconnect Tiles (INT_L, INT_R) and CLB Tiles (CLBLM_L, CLBLM_R, CLBLL_L, CLBLL_R)
    # are possible types.
    # QUESTION: Is this a complete list of possible tile types with switchboxes?
    set pip_tiles [get_tiles -filter "(ROW >= $min_row && ROW <= $max_row && COLUMN <= $max_col && COLUMN >= $min_col) && (TILE_TYPE == INT_L || TILE_TYPE == INT_R || TILE_TYPE == CLBLM_L || TILE_TYPE == CLBLM_R || TILE_TYPE == CLBLL_L || TILE_TYPE == CLBLL_R) "] 
    set diff_time [tincr::report_runtime "get_used_pips [subst -novariables {$pip_tiles $channel_out}]" s]
    ::tincr::print_verbose "Found used PIPs...($diff_time seconds)"
    
    # 2. Get static and routethrough LUT BELs.
    # Get used sites within the reconfigurable region.
    # TODO: Don't duplicate the write_static_and_routethrough_luts process.
    set tiles [get_tiles -filter "(ROW >= $min_row && ROW <= $max_row && COLUMN <= $max_col && COLUMN >= $min_col)"] 
    set site_list [get_sites -quiet -filter IS_USED -of_objects $tiles] 
    set diff_time [tincr::report_runtime "write_static_and_routethrough_luts [subst -novariables {$site_list $channel_out}]" s]
    ::tincr::print_verbose "Found static & route-through LUTs...($diff_time seconds)"

    # 3. Get site rouethroughs
    set diff_time [tincr::report_runtime "get_site_routethroughs [subst -novariables {$tiles $channel_out}]" s]
    ::tincr::print_verbose "Found site route-throughs...($diff_time seconds)"
    
    # 4. Get complete static routes
    set static_nets [get_nets -of_objects [get_cells -hierarchical -filter { IS_BLACKBOX == "TRUE" } ] ] 
    set diff_time [tincr::report_runtime "get_static_routes [subst -novariables {$static_nets $channel_out}]" s]
	::tincr::print_verbose "Found static portions of nets...($diff_time seconds)"
    
    
    close_project
    close $channel_out
}


