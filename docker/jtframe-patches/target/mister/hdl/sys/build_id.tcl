
# SFTM-specific fix: copy sys_top.sdc into the Quartus project directory.
#
# ../mister.qsf references "SDC_FILE sys_top.sdc" (a bare filename, resolved
# relative to the Quartus project directory) with the comment "SDC file is
# copied and edited in the target folder" -- but nothing in the stock
# jtframe/jtcore project-generation flow actually performs that copy for
# this project. Every build has therefore reported:
#   Critical Warning (332012): Synopsys Design Constraints File file not
#   found: 'sys_top.sdc' ... the Compiler will not properly optimize the
#   design.
# and proceeded with NO clock constraints at all (no create_clock, no
# derive_pll_clocks) for the entire design -- meaning Quartus's timing
# analysis of every clock domain, including the CPU/ROM logic, has never
# actually been valid. This PRE_FLOW_SCRIPT_FILE hook is already the
# earliest point in the Quartus flow that runs after the project directory
# exists (same mechanism build_id_verilog below relies on), so it's the
# natural place to perform the copy ourselves.
#
# The vendored sys_top.sdc has no per-project placeholders (checked --
# it's generic MiSTer-framework port/PLL names throughout), so a plain
# copy is sufficient despite the "copied and edited" wording.
proc copySysTopSdc {} {
    set srcDir [file dirname [info script]]
    set src [file join $srcDir sys_top.sdc]
    set dst [file join [pwd] sys_top.sdc]
    if { [file exists $src] } {
        file copy -force $src $dst
        post_message "Copied $src -> $dst"
    } else {
        post_message -type error "sys_top.sdc not found at $src (expected alongside build_id.tcl)"
    }
}

# Build TimeStamp Verilog Module
# Jeff Wiencrot - 8/1/2011
# Sorgelig - 02/11/2019
proc generateBuildID_Verilog {} {

	# Get the timestamp (see: http://www.altera.com/support/examples/tcl/tcl-date-time-stamp.html)
	set buildDate "`define BUILD_DATE \"[clock format [ clock seconds ] -format %y%m%d]\""

	# Create a Verilog file for output
	set outputFileName "build_id.v"
	
	set fileData ""
	if { [file exists $outputFileName]} {
		set outputFile [open $outputFileName "r"]
		set fileData [read $outputFile]
		close $outputFile	
	}

	if {$buildDate ne $fileData} {
		set outputFile [open $outputFileName "w"]
		puts -nonewline $outputFile $buildDate
		close $outputFile
		# Send confirmation message to the Messages window
		post_message "Generated: [pwd]/$outputFileName: $buildDate"
	}
}

# Build CDF file
# Sorgelig - 17/2/2018
proc generateCDF {revision device outpath} {

	set outputFileName "jtag.cdf"
	set outputFile [open $outputFileName "w"]

	puts $outputFile "JedecChain;"
	puts $outputFile "	FileRevision(JESD32A);"
	puts $outputFile "	DefaultMfr(6E);"
	puts $outputFile ""
	puts $outputFile "	P ActionCode(Ign)"
	puts $outputFile "		Device PartName(SOCVHPS) MfrSpec(OpMask(0));"
	puts $outputFile "	P ActionCode(Cfg)"
	puts $outputFile "		Device PartName($device) Path(\"$outpath/\") File(\"$revision.sof\") MfrSpec(OpMask(1));"
	puts $outputFile "ChainEnd;"
	puts $outputFile ""
	puts $outputFile "AlteraBegin;"
	puts $outputFile "	ChainType(JTAG);"
	puts $outputFile "AlteraEnd;"
}

copySysTopSdc

set project_name [lindex $quartus(args) 1]
set revision [lindex $quartus(args) 2]

if {[project_exists $project_name]} {
    if {[string equal "" $revision]} {
        project_open $project_name -revision [get_current_revision $project_name]
    } else {
        project_open $project_name -revision $revision
    }
} else {
    post_message -type error "Project $project_name does not exist"
    exit
}

set device  [get_global_assignment -name DEVICE]
set outpath [get_global_assignment -name PROJECT_OUTPUT_DIRECTORY]

if [is_project_open] {
    project_close
}

generateBuildID_Verilog
generateCDF $revision $device $outpath
